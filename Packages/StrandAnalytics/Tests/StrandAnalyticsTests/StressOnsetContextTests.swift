import XCTest
@testable import StrandAnalytics

/// D4-10 / D6-04: the stress-onset slow baseline only learns from rest ticks, context suppresses
/// locomotion / unknown / asleep / post-exertion / post-transition dips, and stillness is never claimed
/// unless it was verified.
final class StressOnsetContextTests: XCTestCase {

    private let on = StressOnsetDetector.Config(enabled: true, autoNudge: true)
    private func jittered(_ rrMs: Int, jitter: Int, _ n: Int = 60) -> [Int] {
        (0..<n).map { rrMs + ($0 % 2 == 0 ? jitter : -jitter) }
    }
    private let still = StressOnsetDetector.LiveContext(activity: .still)

    private func seed(ticks: Int = 60, at t0: Int = 10_000) -> (StressOnsetDetector.State, Int) {
        var st = StressOnsetDetector.State.initial
        var t = t0
        for _ in 0..<ticks {
            st = StressOnsetDetector.evaluate(rrBuffer: jittered(900, jitter: 25), currentHR: 65,
                                              recentMotionG: 0, sessionActive: false, state: st, config: on,
                                              nowSec: t, tzOffsetSec: 0, context: still).nextState
            t += 10
        }
        return (st, t)
    }

    /// 60 seated ticks at RMSSD ~50, then 30 exercise ticks at RMSSD ~20 with motion above the gate: the
    /// slow baseline is still ~50 afterwards (it used to absorb every exercise tick).
    func testExerciseTicksDoNotDragTheSlowBaseline() {
        var (st, t) = seed()
        let before = st.baselineRMSSD
        XCTAssertEqual(before, 50, accuracy: 1)
        for _ in 0..<30 {
            let d = StressOnsetDetector.evaluate(rrBuffer: jittered(600, jitter: 10), currentHR: 95,
                                                 recentMotionG: 0.5, sessionActive: false, state: st,
                                                 config: on, nowSec: t, tzOffsetSec: 0,
                                                 context: .init(activity: .moving))
            XCTAssertFalse(d.baselineUpdated)
            XCTAssertFalse(d.shouldNudge)
            st = d.nextState
            t += 10
        }
        XCTAssertEqual(st.baselineRMSSD, before, accuracy: 1e-12)
        // Old behaviour, for the record: 30 ticks of 0.98 EMA toward 20 would have moved it ~13 ms.
        let oldDrag = before - (pow(0.98, 30) * before + (1 - pow(0.98, 30)) * 20)
        XCTAssertGreaterThan(oldDrag, 10)
    }

    /// A sit-to-stand transition followed by an orthostatic RMSSD drop (HR in band, wrist still) arms a
    /// dip, but it is gated as a transition, not a stress onset; and those ticks do not move the baseline.
    func testADipRightAfterAPosturalTransitionDoesNotFire() {
        var (st, t) = seed()
        let base = st.baselineRMSSD
        let ctx = StressOnsetDetector.LiveContext(activity: .still, lastTransitionAt: t)
        var d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80, recentMotionG: 0,
                                             sessionActive: false, state: st, config: on, nowSec: t + 10,
                                             tzOffsetSec: 0, context: ctx)
        XCTAssertEqual(d.reason, .awaitingSustain)
        XCTAssertFalse(d.baselineUpdated)
        st = d.nextState
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80, recentMotionG: 0,
                                         sessionActive: false, state: st, config: on,
                                         nowSec: t + 10 + StressOnsetDetector.sustainSeconds,
                                         tzOffsetSec: 0, context: ctx)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .transitionGated)
        XCTAssertEqual(d.nextState.baselineRMSSD, base, accuracy: 1e-12)

        // The same dip with no transition fires, and says stillness was verified.
        (st, t) = seed()
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80, recentMotionG: 0,
                                         sessionActive: false, state: st, config: on, nowSec: t,
                                         tzOffsetSec: 0, context: still)
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80, recentMotionG: 0,
                                         sessionActive: false, state: d.nextState, config: on,
                                         nowSec: t + StressOnsetDetector.sustainSeconds, tzOffsetSec: 0,
                                         context: still)
        XCTAssertTrue(d.shouldNudge)
        XCTAssertTrue(d.stillnessVerified)
    }

    /// Locomotion, unknown activity, sleep and the post-exertion window all suppress (and freeze the EMA).
    func testContextSuppressesLocomotionUnknownSleepAndPostExertion() {
        let contexts: [StressOnsetDetector.LiveContext] = [
            .init(activity: .moving), .init(activity: .unknown), .init(activity: .still, asleep: true),
        ]
        for c in contexts {
            var (st, t) = seed()
            let base = st.baselineRMSSD
            var d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80,
                                                 recentMotionG: nil, sessionActive: false, state: st, config: on,
                                                 nowSec: t, tzOffsetSec: 0, context: c)
            st = d.nextState; t += StressOnsetDetector.sustainSeconds
            d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80,
                                             recentMotionG: nil, sessionActive: false, state: st, config: on,
                                             nowSec: t, tzOffsetSec: 0, context: c)
            XCTAssertFalse(d.shouldNudge, "\(c)")
            XCTAssertEqual(d.reason, .contextGated, "\(c)")
            XCTAssertEqual(d.nextState.baselineRMSSD, base, accuracy: 1e-12, "\(c)")
        }
        var (st, t) = seed()
        let post = StressOnsetDetector.LiveContext(activity: .still, lastExertionEndAt: t - 600)
        st = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80, recentMotionG: 0,
                                          sessionActive: false, state: st, config: on, nowSec: t,
                                          tzOffsetSec: 0, context: post).nextState
        t += StressOnsetDetector.sustainSeconds
        let d = StressOnsetDetector.evaluate(rrBuffer: jittered(800, jitter: 5), currentHR: 80, recentMotionG: 0,
                                             sessionActive: false, state: st, config: on, nowSec: t,
                                             tzOffsetSec: 0, context: post)
        XCTAssertEqual(d.reason, .contextGated)
    }

    /// No context supplied: behaviour is the HR-band gate as before, but stillness is reported unverified,
    /// so the caller cannot claim the user was "still".
    func testNoContextNeverClaimsVerifiedStillness() {
        var st = StressOnsetDetector.State.initial
        var d = StressOnsetDetector.evaluate(rrBuffer: jittered(900, jitter: 60), currentHR: 70, recentMotionG: nil,
                                             sessionActive: false, state: st, config: on, nowSec: 0, tzOffsetSec: 0)
        st = d.nextState
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(900, jitter: 5), currentHR: 70, recentMotionG: nil,
                                         sessionActive: false, state: st, config: on, nowSec: 60, tzOffsetSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: jittered(900, jitter: 5), currentHR: 70, recentMotionG: nil,
                                         sessionActive: false, state: d.nextState, config: on,
                                         nowSec: 60 + StressOnsetDetector.sustainSeconds, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        XCTAssertFalse(d.stillnessVerified)
    }
}

/// The stored-context reducer the AppModel call site uses.
final class StressOnsetLiveContextTests: XCTestCase {
    private func iv(_ s: Int, _ e: Int, _ c: ActivityClass) -> ActivityContextInterval {
        ActivityContextInterval(start: s, end: e, activityClass: c, confidence: 0.8)
    }

    func testCurrentRunDrivesActivityAndBoundariesGiveTransitions() {
        let runs = [iv(0, 600, .walking), iv(600, 1_800, .sitting), iv(1_800, 1_900, .standing),
                    iv(1_900, 2_400, .stationary)]
        let c = StressOnsetDetector.liveContext(intervals: runs, nowSec: 2_000)
        XCTAssertEqual(c.activity, .still)
        XCTAssertEqual(c.lastTransitionAt, 1_800, "sit -> stand; stand -> unresolved is not a transition")
        XCTAssertEqual(c.lastExertionEndAt, 600)
        XCTAssertFalse(c.asleep)
    }

    func testStaleOrMissingContextIsNoEvidenceAndUnknownIsUnknown() {
        XCTAssertEqual(StressOnsetDetector.liveContext(intervals: [], nowSec: 100).activity, .none)
        let stale = StressOnsetDetector.liveContext(intervals: [iv(0, 600, .sitting)],
                                                    nowSec: 600 + StressOnsetDetector.contextMaxAgeSeconds + 1)
        XCTAssertEqual(stale.activity, .none)
        XCTAssertEqual(StressOnsetDetector.liveContext(intervals: [iv(0, 600, .unknown)], nowSec: 300).activity,
                       .unknown)
        XCTAssertEqual(StressOnsetDetector.liveContext(intervals: [iv(0, 600, .running)], nowSec: 300).activity,
                       .moving)
        let sleep = StressOnsetDetector.liveContext(intervals: [iv(0, 600, .sleeping)], nowSec: 300)
        XCTAssertTrue(sleep.asleep)
    }
}
