import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class DayStateTimelineTests: XCTestCase {
    private let t0 = 1_800_000_000

    private func hr(_ fromMin: Int, _ toMin: Int, bpm: Int = 70) -> [HRSample] {
        (fromMin * 60 ..< toMin * 60).map { HRSample(ts: t0 + $0, bpm: bpm) }
    }

    /// Gravity with a constant per-second step of `delta` g, so the mean delta equals `delta`.
    private func gravity(_ fromMin: Int, _ toMin: Int, delta: Double) -> [GravitySample] {
        (fromMin * 60 ..< toMin * 60).map { s in
            GravitySample(ts: t0 + s, x: delta * Double(s), y: 0, z: 1)
        }
    }

    private func steps(_ fromMin: Int, _ toMin: Int, cls: Int) -> [StepSample] {
        (fromMin * 60 ..< toMin * 60).map { StepSample(ts: t0 + $0, counter: $0, activityClass: cls) }
    }

    private func build(_ minutes: Int, hr: [HRSample], gravity: [GravitySample] = [], steps: [StepSample] = [],
                       sleep: [DayStateSpan] = [], workouts: [DayStateWorkout] = [],
                       offWrist: [DayStateSpan] = []) -> [DayStateSegment] {
        DayStateTimeline.build(dayStart: t0, dayEnd: t0 + minutes * 60, hr: hr, gravity: gravity, steps: steps,
                               sleep: sleep, workouts: workouts, offWrist: offWrist)
    }

    func testStillAndActiveFromGravity() {
        let segs = build(20, hr: hr(0, 20),
                         gravity: gravity(0, 10, delta: 0.01) + gravity(10, 20, delta: 0.5))
        XCTAssertEqual(segs.map(\.state), [.still, .active])
        XCTAssertEqual(segs[0].end, t0 + 600)
        XCTAssertEqual(segs[0].avgHr, 70)
        XCTAssertEqual(segs[0].basis, .motion)
    }

    func testNoPulseWithRecordsIsOffWristButSilenceIsNoData() {
        let g = gravity(0, 10, delta: 0.01)
        let segs = build(20, hr: [], gravity: g)
        XCTAssertEqual(segs.map(\.state), [.offWrist, .noData])
        XCTAssertEqual(segs[0].basis, .noPulseSignal)
        XCTAssertNil(segs[0].avgHr)
    }

    func testSleepSessionWinsOverMotionAndMissingPulse() {
        let segs = build(30, hr: hr(0, 10), gravity: gravity(0, 30, delta: 0.5),
                         sleep: [DayStateSpan(start: t0, end: t0 + 1800)])
        XCTAssertEqual(segs.map(\.state), [.sleeping])
        XCTAssertEqual(segs[0].basis, .sleepSession)
    }

    func testExplicitWristOffSpan() {
        let segs = build(20, hr: hr(0, 20), gravity: gravity(0, 20, delta: 0.01),
                         offWrist: [DayStateSpan(start: t0 + 600, end: t0 + 1200)])
        XCTAssertEqual(segs.map(\.state), [.still, .offWrist])
        XCTAssertEqual(segs[1].basis, .wristEvent)
    }

    func testStrapWalkAndRunLabels() {
        let segs = build(30, hr: hr(0, 30), gravity: gravity(0, 30, delta: 0.3),
                         steps: steps(0, 10, cls: 0) + steps(10, 20, cls: 1) + steps(20, 30, cls: 2))
        XCTAssertEqual(segs.map(\.state), [.active, .walking, .running])
        XCTAssertEqual(segs[1].basis, .strapActivityClass)
        XCTAssertEqual(segs[1].locomotionShare ?? 0, 1, accuracy: 0.001)
    }

    func testLoggedRunningWorkoutOverridesMotion() {
        let segs = build(20, hr: hr(0, 20, bpm: 150), gravity: gravity(0, 20, delta: 0.01),
                         workouts: [DayStateWorkout(start: t0 + 300, end: t0 + 900, sport: "Running")])
        XCTAssertEqual(segs.map(\.state), [.still, .running, .still])
        XCTAssertEqual(segs[1].workoutSport, "Running")
    }

    func testOtherSportIsGenericWorkout() {
        let segs = build(10, hr: hr(0, 10), gravity: gravity(0, 10, delta: 0.01),
                         workouts: [DayStateWorkout(start: t0, end: t0 + 600, sport: "Cycling")])
        XCTAssertEqual(segs.map(\.state), [.workout])
    }

    /// Whole-day step stream: `cls` and a counter ticking `perSecond` inside [from, to) seconds, still and flat
    /// elsewhere, so the stream is continuous like the strap's.
    private func stepStream(_ minutes: Int, burst from: Int, _ to: Int, cls: Int = 1, perSecond: Int = 2,
                            classOnly: Bool = false) -> [StepSample] {
        var counter = 0
        return (0 ..< minutes * 60).map { s in
            let inBurst = s >= from && s < to
            if inBurst && !classOnly { counter += perSecond }
            return StepSample(ts: t0 + s, counter: counter, activityClass: inBurst ? cls : 0)
        }
    }

    func testSixteenSecondWalkInsideStillMinutesGetsItsOwnBox() {
        let burst = 20 * 60 + 7
        let segs = build(40, hr: hr(0, 40), gravity: gravity(0, 40, delta: 0.01),
                         steps: stepStream(40, burst: burst, burst + 16))
        XCTAssertEqual(segs.map(\.state), [.still, .walking, .still])
        XCTAssertEqual(segs[1].start, t0 + burst)
        XCTAssertEqual(segs[1].durationSeconds, 16)
        XCTAssertEqual(segs[1].basis, .strapActivityClass)
        XCTAssertEqual(segs[1].stepTicks, 32)
    }

    func testBurstBridgesShortDropoutsButNotLongOnes() {
        let first = stepStream(40, burst: 1200, 1210)
        let second = stepStream(40, burst: 1215, 1225)
        let merged = zip(first, second).map { a, b in StepSample(ts: a.ts, counter: a.counter + b.counter,
                                                              activityClass: max(a.activityClass ?? 0, b.activityClass ?? 0)) }
        let segs = build(40, hr: hr(0, 40), gravity: gravity(0, 40, delta: 0.01), steps: merged)
        XCTAssertEqual(segs.filter { $0.state == .walking }.count, 1)
        XCTAssertEqual(segs.first { $0.state == .walking }?.durationSeconds, 25)

        let far = stepStream(40, burst: 1200, 1210)
        let farSecond = stepStream(40, burst: 1230, 1240)
        let apart = zip(far, farSecond).map { a, b in StepSample(ts: a.ts, counter: a.counter + b.counter,
                                                                 activityClass: max(a.activityClass ?? 0, b.activityClass ?? 0)) }
        let two = build(40, hr: hr(0, 40), gravity: gravity(0, 40, delta: 0.01), steps: apart)
        XCTAssertEqual(two.filter { $0.state == .walking }.count, 2)
    }

    func testBurstTooShortOrWithoutStepTicksIsIgnored() {
        let tooShort = build(30, hr: hr(0, 30), gravity: gravity(0, 30, delta: 0.01),
                             steps: stepStream(30, burst: 900, 906))
        XCTAssertEqual(tooShort.map(\.state), [.still])

        let labelOnly = build(30, hr: hr(0, 30), gravity: gravity(0, 30, delta: 0.01),
                              steps: stepStream(30, burst: 900, 930, classOnly: true))
        XCTAssertEqual(labelOnly.map(\.state), [.still])
    }

    func testRunBurstIsRunning() {
        let segs = build(30, hr: hr(0, 30, bpm: 150), gravity: gravity(0, 30, delta: 0.01),
                         steps: stepStream(30, burst: 600, 660, cls: 2, perSecond: 3))
        XCTAssertEqual(segs.map(\.state), [.still, .running, .still])
    }

    func testBurstNeverSplitsSleepOrOffWrist() {
        let steps = stepStream(30, burst: 600, 640)
        let asleep = build(30, hr: hr(0, 30), gravity: gravity(0, 30, delta: 0.01), steps: steps,
                           sleep: [DayStateSpan(start: t0, end: t0 + 1800)])
        XCTAssertEqual(asleep.map(\.state), [.sleeping])

        let off = build(30, hr: hr(0, 30), gravity: gravity(0, 30, delta: 0.01), steps: steps,
                        offWrist: [DayStateSpan(start: t0, end: t0 + 1800)])
        XCTAssertEqual(off.map(\.state), [.offWrist])
    }

    func testSingleMovingMinuteIsFoldedIntoNeighbour() {
        var x = 0.0
        var g: [GravitySample] = []
        for s in 0 ..< 20 * 60 {
            x += (s / 60 == 10) ? 0.5 : 0.01
            g.append(GravitySample(ts: t0 + s, x: x, y: 0, z: 1))
        }
        let segs = build(20, hr: hr(0, 20), gravity: g)
        XCTAssertEqual(segs.map(\.state), [.still])
        XCTAssertEqual(segs[0].durationSeconds, 1200)
    }

    func testHeartRateWithoutMotionDataIsWornUnknown() {
        let segs = build(10, hr: hr(0, 10))
        XCTAssertEqual(segs.map(\.state), [.wornUnknown])
        XCTAssertEqual(segs[0].basis, .noMotionData)
    }

    func testTotalsSumToCoveredSpan() {
        let segs = build(20, hr: hr(0, 10), gravity: gravity(0, 20, delta: 0.01))
        let totals = DayStateTimeline.totals(segs)
        XCTAssertEqual(totals.values.reduce(0, +), 1200)
        XCTAssertEqual(totals[.offWrist], 600)
    }

    func testImplausibleHeartRateIsIgnored() {
        let bad = (0 ..< 600).map { HRSample(ts: t0 + $0, bpm: 255) }
        let segs = build(10, hr: bad, gravity: gravity(0, 10, delta: 0.01))
        XCTAssertEqual(segs.map(\.state), [.offWrist])
    }
}
