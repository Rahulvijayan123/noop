import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StretchDetailTests: XCTestCase {

    private let t0 = 1_760_000_000

    func testSliceLengthGrowsWithTheStretchAndKeepsItUnderTheLimit() {
        XCTAssertEqual(StretchDetailBuilder.binSeconds(forDuration: 120), 5)
        XCTAssertEqual(StretchDetailBuilder.binSeconds(forDuration: 400), 10)
        XCTAssertEqual(StretchDetailBuilder.binSeconds(forDuration: 3_600), 120)
        XCTAssertEqual(StretchDetailBuilder.binSeconds(forDuration: 3 * 3_600), 300)
        for seconds in [10, 95, 600, 1_800, 5_400, 14_400, 40_000] {
            let size = StretchDetailBuilder.binSeconds(forDuration: seconds)
            XCTAssertLessThanOrEqual((seconds + size - 1) / size, 40, "\(seconds)s")
        }
    }

    func testSummaryAndSlicesAgreeOnHeartRate() throws {
        // 10 minutes: the first half at 60 bpm, the second at 100 bpm.
        let hr = (0..<600).map { HRSample(ts: t0 + $0, bpm: $0 < 300 ? 60 : 100) }
        let d = StretchDetailBuilder.build(start: t0, end: t0 + 600, hr: hr, gravity: [], steps: [])
        XCTAssertEqual(d.avgHr, 80)
        XCTAssertEqual(d.minHr, 60)
        XCTAssertEqual(d.maxHr, 100)
        XCTAssertEqual(d.hrCoverage, 1, accuracy: 1e-9)
        XCTAssertEqual(d.bins.first?.avgHr, 60)
        XCTAssertEqual(d.bins.last?.avgHr, 100)
        XCTAssertEqual(d.bins.reduce(0) { $0 + $1.durationSeconds }, 600)
        XCTAssertEqual(d.bins.first?.start, t0)
        XCTAssertEqual(d.bins.last?.end, t0 + 600)
        XCTAssertNil(d.meanMotionG)
        XCTAssertNil(d.stepTicks)
    }

    func testReadingsOutsideTheStretchAndImplausibleOnesAreIgnored() {
        let hr = [HRSample(ts: t0 - 5, bpm: 150), HRSample(ts: t0, bpm: 70), HRSample(ts: t0 + 1, bpm: 12),
                  HRSample(ts: t0 + 2, bpm: 72), HRSample(ts: t0 + 60, bpm: 150)]
        let d = StretchDetailBuilder.build(start: t0, end: t0 + 60, hr: hr, gravity: [], steps: [])
        XCTAssertEqual(d.avgHr, 71)
        XCTAssertEqual(d.maxHr, 72)
        XCTAssertEqual(d.hrCoverage, 2.0 / 60.0, accuracy: 1e-9)
    }

    func testMotionIsTheChangeInTheGravityVector() throws {
        // 1 g along z, then a 0.3 g step in x on every second sample after the first.
        var g: [GravitySample] = []
        for i in 0..<60 {
            let x = i % 2 == 0 ? 0.0 : 0.3
            g.append(GravitySample(ts: t0 + i, x: x, y: 0, z: 1))
        }
        let d = StretchDetailBuilder.build(start: t0, end: t0 + 60, hr: [], gravity: g, steps: [])
        let mean = try XCTUnwrap(d.meanMotionG)
        XCTAssertEqual(mean, 0.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(d.peakMotionG), 0.3, accuracy: 1e-9)
        XCTAssertTrue(d.hasSignal)
        XCTAssertNil(d.avgHr)
    }

    func testStepTicksCountCounterDeltasAndWrapAround() throws {
        var steps: [StepSample] = []
        var counter = 0xFFF0
        for i in 0..<30 {
            steps.append(StepSample(ts: t0 + i, counter: counter & 0xFFFF, activityClass: i >= 10 ? 1 : 0))
            counter += 2
        }
        let d = StretchDetailBuilder.build(start: t0, end: t0 + 30, hr: [], gravity: [], steps: steps)
        // 29 deltas of 2 inside the stretch (the first sample has no earlier one).
        XCTAssertEqual(d.stepTicks, 58)
        XCTAssertEqual(try XCTUnwrap(d.locomotionShare), 20.0 / 30.0, accuracy: 1e-9)
    }

    func testAnEmptyOrInvertedRangeIsHarmless() {
        let d = StretchDetailBuilder.build(start: t0, end: t0, hr: [], gravity: [], steps: [])
        XCTAssertTrue(d.bins.isEmpty)
        XCTAssertFalse(d.hasSignal)
    }
}
