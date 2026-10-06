import XCTest
@testable import StrandAnalytics

final class ActivityContextAggregateTests: XCTestCase {
    private let t0 = 1_760_000_000

    /// `diffSqSum`/`diffCount` default to nil, which leaves the interval's `rrDiffSqSumMs2`/`rrDiffCount`
    /// at 0 — exactly what a row persisted before those columns existed looks like — so a test that omits
    /// them exercises `ActivityContextAggregator`'s legacy-row fallback (approximated from `rmssd`/`beats`
    /// assuming full contiguity), while a test that supplies them exercises the exact modern path.
    private func iv(_ s: Int, _ e: Int, _ c: ActivityClass, conf: Double = 0.8, hr: Double? = nil, hrN: Int = 0,
                    rmssd: Double? = nil, beats: Int = 0, diffSqSum: Double? = nil, diffCount: Int? = nil,
                    resp: Double? = nil, breaths: Int = 0,
                    ticks: Int = 0, cadence: Double? = nil, hrMin: Int? = nil, hrMax: Int? = nil) -> ActivityContextInterval {
        ActivityContextInterval(start: t0 + s, end: t0 + e, activityClass: c, confidence: conf,
                                stepTicks: ticks, cadenceSpm: cadence, hrSamples: hrN, hrMean: hr, hrMin: hrMin, hrMax: hrMax,
                                rmssd: rmssd, rrBeats: beats,
                                rrDiffSqSumMs2: diffSqSum ?? 0, rrDiffCount: diffCount ?? 0,
                                respRateBpm: resp, respBreaths: breaths)
    }

    func testTotalsByClassAreOrderedByTimeThenCode() {
        let s = ActivityContextAggregator.summarize([
            iv(0, 600, .sittingDesk), iv(600, 700, .walking), iv(700, 1_300, .sittingDesk), iv(1_300, 1_400, .running),
        ], from: t0, to: t0 + 1_400)
        XCTAssertEqual(s.classes.map(\.activityClass), [.sittingDesk, .running, .walking], "ties are broken by code, so the order is stable")
        XCTAssertEqual(s.classes.map(\.seconds), [1_200, 100, 100])
        XCTAssertEqual(s.classes.first?.intervals, 2)
        XCTAssertEqual(s.coveredSeconds, 1_400)
        XCTAssertEqual(s.coverage, 1, accuracy: 1e-9)
        XCTAssertEqual(s.aggregate(for: .walking)?.seconds, 100)
        XCTAssertNil(s.aggregate(for: .cycling))
    }

    func testPhysiologyIsWeightedByEvidenceNotByIntervalCount() {
        let s = ActivityContextAggregator.summarize([
            iv(0, 300, .sittingDesk, hr: 60, hrN: 300, rmssd: 60, beats: 300, resp: 12, breaths: 60, hrMin: 55, hrMax: 70),
            iv(300, 400, .sittingDesk, hr: 90, hrN: 100, rmssd: 20, beats: 100, resp: 20, breaths: 20, hrMin: 70, hrMax: 98),
        ], from: t0, to: t0 + 400)
        let a = try! XCTUnwrap(s.aggregate(for: .sittingDesk))
        XCTAssertEqual(try XCTUnwrap(a.hrMean), 67.5, accuracy: 1e-9, "(60*300 + 90*100) / 400")
        XCTAssertEqual(a.hrMin, 55)
        XCTAssertEqual(a.hrMax, 98)
        // RMSSD does NOT average: sqrt(Σ ΔNN² / Σ count), recovered here from the legacy rmssd/beats pair
        // (assuming full contiguity: count = beats − 1), NOT (60*300 + 20*100) / 400 = 50 — that beat-weighted
        // average of two already-square-rooted numbers is the bug this aggregator used to have.
        XCTAssertEqual(try XCTUnwrap(a.rmssd), 52.953, accuracy: 0.001,
                       "sqrt((60²×299 + 20²×99) / (299 + 99)), not a beat-weighted average of rmssd")
        XCTAssertEqual(a.rmssdIntervals, 2)
        XCTAssertEqual(try XCTUnwrap(a.respRateBpm), 14, accuracy: 1e-9, "(12*60 + 20*20) / 80")
        XCTAssertEqual(a.hrSamples, 400)
    }

    func testRMSSDRecombinesSuccessiveDifferenceComponentsNotAWeightedAverage() {
        // Exact components this time (not the legacy approximation): 10 diffs averaging 60² and 90 diffs
        // averaging 20². A beat-weighted average of the two RMSSD VALUES would read 50 (as the old,
        // mathematically wrong implementation did); the correct recombination reads far lower, because
        // the 90 small diffs dominate the sum of squares, not just the count.
        let s = ActivityContextAggregator.summarize([
            iv(0, 300, .sitting, rmssd: 60, beats: 11, diffSqSum: 10 * 60 * 60, diffCount: 10),
            iv(300, 400, .sitting, rmssd: 20, beats: 91, diffSqSum: 90 * 20 * 20, diffCount: 90),
        ], from: t0, to: t0 + 400)
        let a = try! XCTUnwrap(s.aggregate(for: .sitting))
        XCTAssertEqual(try XCTUnwrap(a.rmssd), 26.833, accuracy: 0.001)
        XCTAssertNotEqual(try XCTUnwrap(a.rmssd), 50, accuracy: 1, "must not read the beat-weighted average")
    }

    func testAnIntervalCrossingTheWindowEdgeScalesItsDiffComponentsByTheSameShare() {
        // Half of the first interval's duration is inside the window: its diff components (and therefore
        // its contribution to the combined sum of squares and count) are scaled by that same 0.5 share,
        // exactly like every other evidence-weighted field above.
        let s = ActivityContextAggregator.summarize([
            iv(0, 400, .sitting, rmssd: 40, beats: 41, diffSqSum: 40 * 40 * 40, diffCount: 40),
        ], from: t0 + 200, to: t0 + 400)
        let a = try! XCTUnwrap(s.aggregate(for: .sitting))
        // Halving both the sum of squares and the count leaves the ratio — and so the RMSSD — unchanged.
        XCTAssertEqual(try XCTUnwrap(a.rmssd), 40, accuracy: 1e-9)
    }

    func testAClassWithNoHrvGradeIntervalReportsNoHrv() {
        let s = ActivityContextAggregator.summarize([
            iv(0, 300, .walking, hr: 105, hrN: 300, ticks: 560, cadence: 112),
            iv(300, 600, .walking, hr: 109, hrN: 300, ticks: 600, cadence: 120),
        ], from: t0, to: t0 + 600)
        let a = try! XCTUnwrap(s.aggregate(for: .walking))
        XCTAssertNil(a.rmssd, "motion corrupts beat timing, so none was derived and none is made up")
        XCTAssertNil(a.respRateBpm)
        XCTAssertEqual(a.rmssdIntervals, 0)
        XCTAssertEqual(a.stepTicks, 1_160)
        XCTAssertEqual(try XCTUnwrap(a.cadenceSpm), 116, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(a.hrMean), 107, accuracy: 1e-9)
    }

    func testAnIntervalCrossingTheWindowEdgeCountsOnlyItsOverlap() {
        let s = ActivityContextAggregator.summarize([
            iv(0, 400, .sitting, hr: 70, hrN: 400, rmssd: 40, beats: 400, ticks: 40),
            iv(400, 800, .walking, hr: 100, hrN: 400),
        ], from: t0 + 300, to: t0 + 500)
        XCTAssertEqual(s.coveredSeconds, 200)
        XCTAssertEqual(s.aggregate(for: .sitting)?.seconds, 100)
        XCTAssertEqual(s.aggregate(for: .walking)?.seconds, 100)
        XCTAssertEqual(s.aggregate(for: .sitting)?.hrSamples, 100, "a quarter of the interval's samples")
        XCTAssertEqual(s.aggregate(for: .sitting)?.stepTicks, 10)
        XCTAssertEqual(s.coverage, 1, accuracy: 1e-9)
    }

    func testGapsLowerCoverageAndEmptyInputIsEmpty() {
        let s = ActivityContextAggregator.summarize([iv(0, 100, .sitting), iv(300, 400, .sitting)], from: t0, to: t0 + 1_000)
        XCTAssertEqual(s.coveredSeconds, 200)
        XCTAssertEqual(s.coverage, 0.2, accuracy: 1e-9)
        let none = ActivityContextAggregator.summarize([], from: t0, to: t0 + 1_000)
        XCTAssertTrue(none.classes.isEmpty)
        XCTAssertEqual(none.coverage, 0)
        let degenerate = ActivityContextAggregator.summarize([iv(0, 100, .sitting)], from: t0 + 50, to: t0 + 50)
        XCTAssertEqual(degenerate.coverage, 0)
        XCTAssertTrue(degenerate.classes.isEmpty)
    }

    func testMeanConfidenceIsTimeWeighted() {
        let s = ActivityContextAggregator.summarize([
            iv(0, 300, .standing, conf: 0.9), iv(300, 400, .standing, conf: 0.3),
        ], from: t0, to: t0 + 400)
        XCTAssertEqual(try XCTUnwrap(s.aggregate(for: .standing)?.meanConfidence), 0.75, accuracy: 1e-9)
    }
}
