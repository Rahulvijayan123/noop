import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepAwareStepCounterTests: XCTestCase {
    private func sample(_ ts: Int, _ counter: Int, _ cls: Int? = 1) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }
    private func sleep(stages: [StageSegment] = []) -> SleepSession {
        SleepSession(start: 0, end: 100, efficiency: 1, stages: stages, restingHR: nil, avgHRV: nil)
    }

    func testIsolatedBedMotionIsRejected() {
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow([
            sample(0, 0), sample(1, 1), sample(20, 2)
        ], sleepSessions: [sleep()]))
    }

    func testCoherentNightWalkCounts() {
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow([
            sample(0, 0), sample(1, 2), sample(2, 4), sample(3, 6), sample(4, 8), sample(5, 10)
        ], sleepSessions: [sleep()]), 10)
    }

    func testExplicitWakeGapCountsImmediately() {
        let wake = StageSegment(start: 10, end: 20, stage: "wake")
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow([
            sample(9, 0), sample(10, 2)
        ], sleepSessions: [sleep(stages: [wake])]), 2)
    }

    func testDiagnosticRejectionReasonsAreSeparated() {
        // +25 in one second is neither gait nor a bout block; +7 across two seconds is a block.
        let count = SleepAwareStepCounter.count([
            sample(0, 100, 0), sample(1, 102, 1), sample(2, 127, 1),
            sample(4, 134, 2), sample(5, 137, 0)
        ], sleepSessions: [])
        XCTAssertEqual(count.totalTicks, 9)
        XCTAssertEqual(count.rejectedActivityClassTicks, 3)
        XCTAssertEqual(count.rejectedImplausibleTicks, 25)
    }

    func testBoutBlockCountsOutsideSleepWhateverItsLabel() {
        let samples = [sample(0, 100, 0), sample(1, 106, 0)]
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(samples, sleepSessions: []), 6)
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(samples, sleepSessions: []),
                       StepsCounter.stepsInWindow(samples))
        XCTAssertEqual(SleepAwareStepCounter.count(samples, sleepSessions: []).rejectedActivityClassTicks, 0)
    }

    func testIsolatedBoutBlockInsideScoredSleepIsStillRejected() {
        let count = SleepAwareStepCounter.count([sample(0, 100, 0), sample(1, 106, 0)],
                                                sleepSessions: [sleep()])
        XCTAssertEqual(count.totalTicks, 0)
        XCTAssertEqual(count.rejectedIsolatedSleepTicks, 6)
    }
}
