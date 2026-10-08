import XCTest
@testable import StrandAnalytics

/// D9-07: the wearer's stretch corrections overlay the decoder's intervals at read time.
final class ActivityContextCorrectionsTests: XCTestCase {
    private let t0 = 1_790_870_400

    private func sitting(_ s: Int, _ e: Int) -> ActivityContextInterval {
        ActivityContextInterval(start: s, end: e, activityClass: .sitting, confidence: 0.6, runnerUp: .stationary,
                                runnerUpConfidence: 0.3, posture: .seatedLikely, locomotion: .stationary,
                                armBehavior: .quiet, sleep: .awake, wear: .onWrist, stepTicks: 7,
                                hrSamples: 600, hrMean: 62, hrMin: 55, hrMax: 70, rmssd: 40, rrBeats: 700,
                                rrDiffSqSumMs2: 1_120_000, rrDiffCount: 700, respRateBpm: 14, respBreaths: 140,
                                transitionCount: 3, absorbedSeconds: 30, precededByGapS: 12, settlingSeconds: 120)
    }

    private func feedback(_ s: Int, _ e: Int, _ label: StretchCorrection?, verdict: StretchVerdict = .incorrect,
                          at seconds: TimeInterval = 0) -> StretchFeedback {
        StretchFeedback(kind: .activityContext, startTs: s, endTs: e, deviceId: "d", predictedLabel: "Sitting",
                        predictedClass: "sitting", predictedConfidence: 0.6, verdict: verdict,
                        correctedLabel: label, now: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    func testNotWearingSplitsTheRowAndTakesTheSecondsOffWrist() throws {
        // The critic's scenario: sitting [0, 600) with "not wearing" over [100, 400).
        let out = ActivityContextCorrections.applying([feedback(t0 + 100, t0 + 400, .notWearing)],
                                                      to: [sitting(t0, t0 + 600)])
        XCTAssertEqual(out.map(\.start), [t0, t0 + 100, t0 + 400])
        XCTAssertEqual(out.map(\.end), [t0 + 100, t0 + 400, t0 + 600])
        let lookup = ActivityContextLookup(intervals: out)
        let off = try XCTUnwrap(lookup.interval(at: t0 + 200))
        XCTAssertEqual(off.wear, .offWrist)
        XCTAssertEqual(off.activityClass, .offWrist)
        XCTAssertEqual(off.provenance, ActivityContextProvenance.userCorrection)
        XCTAssertEqual(off.confidence, 1)
        XCTAssertNil(off.hrMean, "nothing measured off the wrist is physiology")
        XCTAssertNil(off.rmssd)
        XCTAssertEqual(off.rrDiffCount, 0)
        let after = try XCTUnwrap(lookup.interval(at: t0 + 500))
        XCTAssertEqual(after.activityClass, .sitting)
        XCTAssertEqual(after.wear, .onWrist)
        XCTAssertNil(after.provenance)
        XCTAssertEqual(after.confidence, 0.6)
        XCTAssertEqual(after.hrMean, 62, "a split piece keeps the row's intensive values")
    }

    func testSplitPiecesConserveTheRowsAdditiveComponents() {
        let row = sitting(t0, t0 + 600)
        // A class correction (not an off-wrist one) over the middle: nothing is cleared, so the pieces sum back.
        let out = ActivityContextCorrections.applying([feedback(t0 + 100, t0 + 333, .lyingDown)], to: [row])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.hrSamples).reduce(0, +), row.hrSamples)
        XCTAssertEqual(out.map(\.rrDiffCount).reduce(0, +), row.rrDiffCount)
        XCTAssertEqual(out.map(\.rrBeats).reduce(0, +), row.rrBeats)
        XCTAssertEqual(out.map(\.stepTicks).reduce(0, +), row.stepTicks)
        XCTAssertEqual(out.map(\.respBreaths).reduce(0, +), row.respBreaths)
        XCTAssertEqual(out.compactMap(\.transitionCount).reduce(0, +), 3)
        XCTAssertEqual(out.map(\.rrDiffSqSumMs2).reduce(0, +), row.rrDiffSqSumMs2, accuracy: 1e-6)
        XCTAssertEqual(out.compactMap(\.settlingSeconds), [100, 20, 0], "settling is the row's first 120 s")
        XCTAssertEqual(out.map(\.precededByGapS), [12, 0, 0])
        // So a rollup over the pieces reads exactly what it read over the row.
        let whole = ActivityContextAggregator.summarize([row], from: t0, to: t0 + 600)
        let split = ActivityContextAggregator.summarize(out, from: t0, to: t0 + 600)
        XCTAssertEqual(whole.coveredSeconds, split.coveredSeconds)
    }

    func testClassCorrectionsSetClassHeadsSleepAndProvenance() throws {
        let row = sitting(t0, t0 + 600)
        func corrected(_ label: StretchCorrection) throws -> ActivityContextInterval {
            try XCTUnwrap(ActivityContextCorrections.applying([feedback(t0, t0 + 600, label)], to: [row]).first)
        }
        let lying = try corrected(.lyingDown)
        XCTAssertEqual(lying.activityClass, .lyingDown)
        XCTAssertEqual(lying.posture, .recumbent)
        XCTAssertEqual(lying.locomotion, .stationary)
        XCTAssertNil(lying.armBehavior, "the wearer said nothing about the arm")
        XCTAssertEqual(lying.sleep, .awake)
        XCTAssertEqual(lying.provenance, ActivityContextProvenance.userCorrection)
        XCTAssertEqual(lying.confidence, 1)
        XCTAssertNil(lying.runnerUp)

        let asleep = try corrected(.asleep)
        XCTAssertEqual(asleep.activityClass, .sleeping)
        XCTAssertEqual(asleep.sleep, .asleep)
        XCTAssertEqual(try corrected(.standing).activityClass, .standing)
        XCTAssertEqual(try corrected(.standing).posture, .uprightStationary)
        XCTAssertEqual(try corrected(.sitting).posture, .seatedLikely)
        let walking = try corrected(.walking)
        XCTAssertEqual(walking.activityClass, .walking)
        XCTAssertEqual(walking.locomotion, .walking)
        XCTAssertNil(walking.posture)
        XCTAssertEqual(walking.hrMean, 62, "a class correction keeps the measured physiology")
    }

    func testTheLatestAnswerWinsWhereTwoOverlap() {
        let older = feedback(t0, t0 + 400, .standing, at: 0)
        let newer = feedback(t0 + 200, t0 + 600, .lyingDown, at: 60)
        for order in [[older, newer], [newer, older]] {
            let out = ActivityContextCorrections.applying(order, to: [sitting(t0, t0 + 600)])
            XCTAssertEqual(out.map(\.activityClass), [.standing, .lyingDown], "\(out.map(\.start))")
            XCTAssertEqual(out.map(\.end), [t0 + 200, t0 + 600])
        }
    }

    func testCorrectionsAcrossSeveralRowsSplitEachAtItsBounds() {
        let rows = [sitting(t0, t0 + 300), sitting(t0 + 300, t0 + 600), sitting(t0 + 900, t0 + 1_200)]
        let out = ActivityContextCorrections.applying([feedback(t0 + 200, t0 + 1_000, .standing)], to: rows)
        XCTAssertEqual(out.map(\.start), [t0, t0 + 200, t0 + 300, t0 + 900, t0 + 1_000])
        XCTAssertEqual(out.map(\.activityClass), [.sitting, .standing, .standing, .standing, .sitting])
        XCTAssertFalse(out.contains { $0.start >= t0 + 600 && $0.end <= t0 + 900 }, "a gap stays a gap")
    }

    func testNoApplicableCorrectionIsANoOp() {
        let rows = [sitting(t0 + 300, t0 + 600), sitting(t0, t0 + 300)]
        let sorted = rows.sorted { $0.start < $1.start }
        XCTAssertEqual(ActivityContextCorrections.applying([], to: rows), sorted)
        // A confirmed stretch, a wrong verdict with no label, a label with no one-to-one class, and a
        // correction outside every row change nothing.
        let inert = [feedback(t0, t0 + 600, nil, verdict: .correct), feedback(t0, t0 + 600, nil),
                     feedback(t0, t0 + 600, .typing), feedback(t0, t0 + 600, .other),
                     feedback(t0 + 5_000, t0 + 6_000, .notWearing)]
        XCTAssertEqual(ActivityContextCorrections.applying(inert, to: rows), sorted)
        XCTAssertEqual(ActivityContextCorrections.corrections(from: inert).count, 1, "only the out-of-range one applies")
    }

    func testProvenanceRoundTripsAndIsAbsentFromDecoderJSON() throws {
        let plain = try JSONEncoder().encode(sitting(t0, t0 + 60))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("provenance"))
        var corrected = sitting(t0, t0 + 60)
        corrected.provenance = ActivityContextProvenance.userCorrection
        let back = try JSONDecoder().decode(ActivityContextInterval.self, from: JSONEncoder().encode(corrected))
        XCTAssertEqual(back.provenance, "user_correction")
        XCTAssertNil(try JSONDecoder().decode(ActivityContextInterval.self, from: plain).provenance)
    }
}
