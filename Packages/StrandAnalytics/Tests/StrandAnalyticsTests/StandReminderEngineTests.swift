import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The rolling stand-reminder rule: at least a minute of standing or movement, accumulated in any pieces,
/// somewhere in the previous 50 minutes - or a reminder.
final class StandReminderEngineTests: XCTestCase {

    /// 12:00:00 UTC on the day of the fixtures: inside the default 09:00-17:00 active hours at offset 0.
    private let noon = 1_760_011_200

    private var config: StandReminderEngine.Config {
        StandReminderEngine.Config(enabled: true, notificationsMasterOn: true)
    }

    /// A timeline that ENDS at `noon`, so the evaluation instant is `noon` unless a test says otherwise.
    private func timeline(_ segments: [(RunKind, Int)], endingAt end: Int? = nil) -> [ActivityContextRun] {
        let total = segments.reduce(0) { $0 + $1.1 }
        return fixtureTimeline(from: (end ?? noon) - total, segments)
    }

    private func decide(_ runs: [ActivityContextRun], steps: [(ts: Int, ticks: Int)] = [],
                        config: StandReminderEngine.Config? = nil, state: StandReminderEngine.State = .initial,
                        now: Int? = nil, worn: Bool = true, tz: Int = 0) -> StandReminderEngine.Decision {
        StandReminderEngine.evaluate(runs: runs, stepTicks: steps, state: state, config: config ?? self.config,
                                     worn: worn, nowSec: now ?? noon, tzOffsetSec: tz)
    }

    private func clip(_ runs: [ActivityContextRun], to end: Int) -> [ActivityContextRun] {
        runs.compactMap { r in
            guard r.start < end else { return nil }
            var c = r
            c.end = min(r.end, end)
            return c
        }
    }

    // MARK: The rule, as the examples in the request put it

    func testFiftyMinutesOfSittingSendsAReminder() {
        let d = decide(timeline([(.desk, 3_000)]))
        XCTAssertTrue(d.shouldRemind)
        XCTAssertEqual(d.reason, .remind)
        XCTAssertEqual(d.window?.movementSeconds, 0)
        XCTAssertEqual(d.window?.sedentarySeconds, 3_000)
        XCTAssertEqual(d.window?.lengthSeconds, 3_000)
        XCTAssertEqual(d.buzzLoops, config.buzzLoops)
        XCTAssertEqual(d.nextState.lastRemindAt, noon)
        XCTAssertEqual(d.nextState.lastEvaluatedThrough, noon)
    }

    func testTwoMinutesOfWalkingInTheWindowMeansNoReminder() {
        let d = decide(timeline([(.desk, 1_500), (.walking, 120), (.desk, 1_380)]))
        XCTAssertFalse(d.shouldRemind)
        XCTAssertEqual(d.reason, .movedEnough)
        XCTAssertEqual(d.window?.movementSeconds, 120)
        XCTAssertEqual(d.nextState.lastRemindAt, 0, "no reminder, nothing to remember")
    }

    func testSeventySecondsOfStandingOrMovingMeansNoReminder() {
        for kind in [RunKind.standing, .light, .walking, .brisk, .running, .cycling, .vigorous] {
            let d = decide(timeline([(.desk, 1_400), (kind, 70), (.desk, 1_530)]))
            XCTAssertEqual(d.reason, .movedEnough, "\(kind)")
            XCTAssertEqual(d.window?.movementSeconds, 70, "\(kind)")
        }
    }

    func testTwentySecondsOfMovementIsStillEligible() {
        let d = decide(timeline([(.desk, 2_000), (.walking, 20), (.desk, 980)]))
        XCTAssertTrue(d.shouldRemind)
        XCTAssertEqual(d.window?.movementSeconds, 20)
    }

    func testTheMinuteDoesNotHaveToBeOneBlock() {
        func bouts(_ n: Int) -> StandReminderEngine.Decision {
            var segments: [(RunKind, Int)] = []
            for _ in 0..<n { segments.append((.desk, 400)); segments.append((.walking, 12)) }
            let used = n * 412
            segments.append((.desk, 3_000 - used))
            return decide(timeline(segments))
        }
        XCTAssertEqual(bouts(7).reason, .movedEnough, "7 x 12 s = 84 s")
        XCTAssertEqual(bouts(7).window?.movementSeconds, 84)
        XCTAssertEqual(bouts(5).reason, .movedEnough, "5 x 12 s = exactly the minute")
        XCTAssertEqual(bouts(4).reason, .remind, "4 x 12 s = 48 s is not enough")
        XCTAssertEqual(bouts(4).window?.movementSeconds, 48)
    }

    func testStandingForTheWholeWindowIsMeaningfulStanding() {
        XCTAssertEqual(decide(timeline([(.standing, 3_000)])).reason, .movedEnough)
    }

    // MARK: Rolling

    func testMovementLeavesTheWindowAndTheReminderComesBack() {
        let all = fixtureTimeline(from: noon - 4_120, [(.desk, 600), (.walking, 120), (.desk, 3_400)])
        let walkEnd = noon - 4_120 + 720
        func at(_ now: Int) -> StandReminderEngine.Decision {
            decide(clip(all, to: now), now: now)
        }
        XCTAssertEqual(at(walkEnd + 100).reason, .insufficientCoverage, "only 13 minutes of data so far")
        XCTAssertEqual(at(walkEnd + 2_880).reason, .movedEnough, "the whole walk is still inside the window")
        // The window start crosses the walk: 60 s of it remain at +2_940, 59 s at +2_941.
        XCTAssertEqual(at(walkEnd + 2_940).reason, .movedEnough)
        XCTAssertEqual(at(walkEnd + 2_940).window?.movementSeconds, 60)
        XCTAssertEqual(at(walkEnd + 2_941).reason, .remind)
        XCTAssertEqual(at(walkEnd + 2_941).window?.movementSeconds, 59)
        XCTAssertEqual(at(walkEnd + 3_400).reason, .remind)
        XCTAssertEqual(at(walkEnd + 3_400).window?.movementSeconds, 0)
    }

    func testTheWindowLengthIsTheUsersSetting() {
        // 90 s of walking 40 minutes ago: outside a 30-minute window, inside a 50-minute one.
        let runs = timeline([(.desk, 600), (.walking, 90), (.desk, 2_310)])
        var thirty = config; thirty.windowMinutes = 30
        let a = decide(runs, config: thirty)
        XCTAssertEqual(a.reason, .remind)
        XCTAssertEqual(a.window?.lengthSeconds, 1_800)
        XCTAssertEqual(decide(runs).reason, .movedEnough)
    }

    // MARK: What counts

    func testShortGestureBlipsNeverAccumulateIntoCredit() {
        var segments: [(RunKind, Int)] = []
        for _ in 0..<30 { segments.append((.desk, 96)); segments.append((.light, 4)) }   // 120 s of "moving", in 4 s blips
        let d = decide(timeline(segments))
        XCTAssertEqual(d.reason, .remind)
        XCTAssertEqual(d.window?.movementSeconds, 0)
        XCTAssertEqual(d.window?.sedentarySeconds, 2_880, "the blips are neither credit nor sedentary time")
    }

    func testNearbyMovementSecondsFormOneBout() {
        // Two 6 s movements 4 s apart are one 16 s bout and count; 6 s alone would not.
        let runs = timeline([(.desk, 2_000), (.light, 6), (.desk, 4), (.light, 6), (.desk, 984)])
        // The 4 s of desk between them sits under the five-second bridge.
        XCTAssertEqual(decide(runs).window?.movementSeconds, 16)
        let apart = timeline([(.desk, 2_000), (.light, 6), (.desk, 20), (.light, 6), (.desk, 968)])
        XCTAssertEqual(decide(apart).window?.movementSeconds, 0)
    }

    func testLyingDownAndUnclearEvidenceNeverTrigger() {
        // Resting on the couch must not be buzzed; evidence with no claim is not "sedentary".
        XCTAssertEqual(decide(timeline([(.lying, 3_000)])).reason, .notSedentary)
        XCTAssertEqual(decide(timeline([(.unclear, 3_000)])).reason, .notSedentary)
        XCTAssertEqual(decide(timeline([(.desk, 1_000), (.lying, 2_000)])).reason, .notSedentary)
    }

    func testEveryKindOfStillnessCountsAsSedentary() {
        let d = decide(timeline([(.fidgeting, 1_000), (.desk, 1_000), (.sitting, 1_000)]))
        XCTAssertEqual(d.reason, .remind)
        XCTAssertEqual(d.window?.sedentarySeconds, 3_000)
    }

    func testAMostlySedentaryWindowWithSomeUnclearTimeStillReminds() {
        let d = decide(timeline([(.desk, 1_400), (.unclear, 300), (.desk, 1_300)]))
        XCTAssertEqual(d.reason, .remind, "90 % sedentary is enough")
        XCTAssertEqual(decide(timeline([(.desk, 1_000), (.unclear, 1_000), (.desk, 1_000)])).reason, .notSedentary)
    }

    func testAsleepOrOffWristTimeIsNotCoveredTime() {
        XCTAssertEqual(decide(timeline([(.asleep, 1_500), (.desk, 1_500)])).reason, .insufficientCoverage,
                       "just woke up: 25 minutes awake is not 50 minutes seated")
        XCTAssertEqual(decide(timeline([(.off, 1_500), (.desk, 1_500)])).reason, .insufficientCoverage)
        XCTAssertEqual(decide(timeline([(.desk, 1_500)])).reason, .insufficientCoverage, "half the window has no data")
    }

    func testStepsCreditMovementTheHeadsReadAsSeated() {
        // Carrying a laptop across the room: the wrist is still, the step counter is not.
        let runs = timeline([(.desk, 3_000)])
        func steps(seconds: Int, from: Int) -> [(ts: Int, ticks: Int)] { (0..<seconds).map { (ts: from + $0, ticks: 2) } }
        let walkedOff = noon - 1_500
        XCTAssertEqual(decide(runs, steps: steps(seconds: 70, from: walkedOff)).reason, .movedEnough)
        XCTAssertEqual(decide(runs, steps: steps(seconds: 70, from: walkedOff)).window?.movementSeconds, 70)
        XCTAssertEqual(decide(runs, steps: steps(seconds: 30, from: walkedOff)).reason, .remind)
        // A stray tick now and then (an arm swing) is not stepping.
        let strays = stride(from: noon - 3_000, to: noon, by: 30).map { (ts: $0, ticks: 1) }
        XCTAssertEqual(decide(runs, steps: strays).window?.movementSeconds, 0)
    }

    func testStepsDoNotCreditTimeAsleepOrOffWrist() {
        let runs = timeline([(.off, 600), (.desk, 2_400)])
        let steps = (0..<120).map { (ts: noon - 3_000 + $0, ticks: 3) }
        XCTAssertEqual(decide(runs, steps: steps).window?.movementSeconds, 0)
    }

    // MARK: Freshness, replay, spacing

    func testDataTheStrapHasNotDeliveredForTwentyMinutesIsNotActedOn() {
        let runs = timeline([(.desk, 3_000)], endingAt: noon - 21 * 60)
        XCTAssertEqual(decide(runs).reason, .staleData)
        XCTAssertEqual(decide(timeline([(.desk, 3_000)], endingAt: noon - 19 * 60)).reason, .remind,
                       "just offloaded: the window ends at the newest data, not at the clock")
    }

    func testTheWindowEndsAtTheNewestDataNotTheClock() {
        let d = decide(timeline([(.desk, 3_000)], endingAt: noon - 600))
        XCTAssertEqual(d.window?.end, noon - 600)
        XCTAssertEqual(d.window?.start, noon - 600 - 3_000)
        XCTAssertEqual(d.nextState.lastEvaluatedThrough, noon - 600)
        XCTAssertEqual(d.nextState.lastRemindAt, noon, "spacing runs on the clock")
    }

    func testReplayingTheSameDataIsANoOp() {
        let runs = timeline([(.desk, 3_000)])
        let first = decide(runs)
        XCTAssertTrue(first.shouldRemind)
        let again = decide(runs, state: first.nextState, now: noon + 60)
        XCTAssertFalse(again.shouldRemind)
        XCTAssertEqual(again.reason, .replayed)
        XCTAssertEqual(again.nextState, first.nextState)
    }

    func testNoRunsIsNoData() {
        XCTAssertEqual(decide([]).reason, .noData)
    }

    func testRemindersAreSpacedWhileTheWearerStaysPut() {
        let long = fixtureTimeline(from: noon - 3_000, [(.desk, 3_000 + 4_000)])
        let first = decide(clip(long, to: noon), now: noon)
        XCTAssertTrue(first.shouldRemind)

        let soon = decide(clip(long, to: noon + 900), state: first.nextState, now: noon + 900)
        XCTAssertEqual(soon.reason, .cooldown, "15 minutes later is inside the 30-minute spacing")
        XCTAssertEqual(soon.nextState.lastRemindAt, noon, "a suppressed reminder does not restart the spacing")

        let later = decide(clip(long, to: noon + 1_900), state: soon.nextState, now: noon + 1_900)
        XCTAssertTrue(later.shouldRemind)
        XCTAssertEqual(later.nextState.lastRemindAt, noon + 1_900)
    }

    func testMovingAfterAReminderRestartsTheWindow() {
        let first = decide(timeline([(.desk, 3_000)]))
        // They get up for two minutes, then sit for 45: the minutes are in the window, so no reminder - and
        // none is owed even though the spacing has long expired.
        let runs = fixtureTimeline(from: noon + 3_600 - 3_000, [(.desk, 100), (.walking, 120), (.desk, 2_780)])
        let d = decide(runs, state: first.nextState, now: noon + 3_600)
        XCTAssertEqual(d.reason, .movedEnough)
    }

    func testAReminderWaitsForTheWearerToFinishGettingUp() {
        // 40 s of movement that has only just ended (or is still going): they are already up.
        let still = decide(timeline([(.desk, 2_960), (.walking, 40)]))
        XCTAssertEqual(still.reason, .recentlyMoving)
        XCTAssertFalse(still.shouldRemind)
        // Half a minute after the movement stopped, with the minute still unfulfilled, the reminder is due.
        let stillSettling = decide(timeline([(.desk, 2_940), (.walking, 40), (.desk, 20)]))
        XCTAssertEqual(stillSettling.reason, .recentlyMoving)
        let settled = decide(timeline([(.desk, 2_930), (.walking, 40), (.desk, 30)]))
        XCTAssertEqual(settled.reason, .remind)
        XCTAssertEqual(settled.window?.movementSeconds, 40)
    }

    // MARK: Gates

    func testGatesStopTheReminderAndSayWhy() {
        let runs = timeline([(.desk, 3_000)])
        var c = config; c.enabled = false
        XCTAssertEqual(decide(runs, config: c).reason, .disabled)

        c = config; c.notificationsMasterOn = false
        XCTAssertEqual(decide(runs, config: c).reason, .notificationsOff)

        c = config; c.quietHoursEnabled = true; c.quietStartMinutes = 11 * 60; c.quietEndMinutes = 13 * 60
        XCTAssertEqual(decide(runs, config: c).reason, .quietHours)

        c = config; c.activeStartMinutes = 13 * 60; c.activeEndMinutes = 17 * 60
        XCTAssertEqual(decide(runs, config: c).reason, .outsideActiveHours)
        c.activeHoursEnabled = false
        XCTAssertEqual(decide(runs, config: c).reason, .remind)

        XCTAssertEqual(decide(runs, worn: false).reason, .notWorn)
        c = config; c.onlyWhenWorn = false
        XCTAssertEqual(decide(runs, config: c, worn: false).reason, .remind)
    }

    func testActiveHoursFollowTheLocalClock() {
        let runs = timeline([(.desk, 3_000)])
        // Noon UTC is 05:00 in UTC-7: outside 09:00-17:00 there, inside it in UTC+0.
        XCTAssertEqual(decide(runs, tz: -7 * 3_600).reason, .outsideActiveHours)
        XCTAssertEqual(decide(runs, tz: 0).reason, .remind)
        XCTAssertEqual(decide(runs, tz: 5 * 3_600 - 60).reason, .remind, "16:59 is inside")
        XCTAssertEqual(decide(runs, tz: 5 * 3_600).reason, .outsideActiveHours, "17:00 sharp is outside")
    }

    func testGatedEvaluationsStillConsumeTheData() {
        // Outside active hours the data is judged and remembered: it is not held for the morning.
        var c = config; c.activeStartMinutes = 13 * 60
        let d = decide(timeline([(.desk, 3_000)]), config: c)
        XCTAssertEqual(d.reason, .outsideActiveHours)
        XCTAssertEqual(d.nextState.lastEvaluatedThrough, noon)
        XCTAssertEqual(d.nextState.lastRemindAt, 0)
    }

    func testStoppedBeforeLookingAtDataLeavesStateAlone() {
        let state = StandReminderEngine.State(lastEvaluatedThrough: 5, lastRemindAt: 7)
        var c = config; c.enabled = false
        XCTAssertEqual(decide(timeline([(.desk, 3_000)]), config: c, state: state).nextState, state)
        XCTAssertEqual(decide([], state: state).nextState, state)
    }

    // MARK: Configuration

    func testLegacySettingsMapOntoTheEngine() {
        let legacy = SedentaryConfig(enabled: true, notificationsMasterOn: true, thresholdMinutes: 50,
                                     reNudgeMinutes: 20, buzzLoops: 3, activeHoursEnabled: false,
                                     activeStartMinutes: 8 * 60, activeEndMinutes: 18 * 60, quietHoursEnabled: true,
                                     quietStartMinutes: 23 * 60, quietEndMinutes: 6 * 60, onlyWhenWorn: false)
        let c = StandReminderEngine.Config(legacy)
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.notificationsMasterOn)
        XCTAssertEqual(c.windowMinutes, 50)
        XCTAssertEqual(c.reNudgeMinutes, 20)
        XCTAssertEqual(c.buzzLoops, 3)
        XCTAssertFalse(c.activeHoursEnabled)
        XCTAssertEqual(c.activeStartMinutes, 480)
        XCTAssertEqual(c.activeEndMinutes, 1_080)
        XCTAssertTrue(c.quietHoursEnabled)
        XCTAssertEqual(c.quietStartMinutes, 1_380)
        XCTAssertEqual(c.quietEndMinutes, 360)
        XCTAssertFalse(c.onlyWhenWorn)
        XCTAssertEqual(c.requiredMovementSeconds, 60)
    }

    func testTheDefaultsAreTheRequestedRule() {
        let c = StandReminderEngine.Config()
        XCTAssertEqual(c.windowMinutes, 50)
        XCTAssertEqual(StandReminderEngine.defaultWindowMinutes, 50)
        XCTAssertEqual(c.requiredMovementSeconds, 60)
        XCTAssertFalse(c.enabled, "opt-in, as the feature always was")
    }

    func testWindowDegenerateInputsAreHarmless() {
        let w = StandReminderEngine.window(runs: [], start: noon, end: noon)
        XCTAssertEqual(w.movementSeconds, 0)
        XCTAssertEqual(w.coverage, 0)
        var odd = fixtureRun(.desk, noon - 100, noon)
        odd.end = odd.start - 50
        let ok = StandReminderEngine.window(runs: [odd], start: noon - 200, end: noon)
        XCTAssertEqual(ok.observedSeconds, 0, "a run that ends before it starts covers nothing")
    }

    // MARK: Against a decoded stream

    /// `liveDay` decodes the way the app does for a day in progress: time outside logged sleep is not yet known
    /// to be awake.
    private func decoded(liveDay: Bool = false, _ build: (inout ActivitySim) -> Void)
        -> (runs: [ActivityContextRun], steps: [(ts: Int, ticks: Int)], end: Int) {
        var probe = ActivitySim(start: noon)
        build(&probe)
        let total = probe.observations.count
        var sim = ActivitySim(start: noon - total)
        build(&sim)
        let input = sim.trackInput(sleepKnownOutsideSessions: !liveDay)
        let track = ActivityContextTrackBuilder.build(input)
        let document = ActivityContextDayDocument(track: track, input: input, generatedAt: noon)
        let ticks = StandReminderEngine.stepTicks(from: input.steps, start: input.dayStart, end: input.dayEnd)
        return (document.runs, ticks, document.runs.map(\.end).max() ?? noon)
    }

    func testAFiftyFiveMinuteDeskSessionWithAShortWalkRemindsAndALongerOneDoesNot() {
        let short = decoded { $0.desk(1_700); $0.walk(15); $0.desk(1_700) }
        let a = decide(short.runs, steps: short.steps, now: short.end)
        XCTAssertEqual(a.reason, .remind, "\(String(describing: a.window))")
        XCTAssertLessThan(a.window?.movementSeconds ?? 99, 60)

        let long = decoded { $0.desk(1_600); $0.walk(150); $0.desk(1_700) }
        let b = decide(long.runs, steps: long.steps, now: long.end)
        XCTAssertEqual(b.reason, .movedEnough, "\(String(describing: b.window))")
        XCTAssertGreaterThanOrEqual(b.window?.movementSeconds ?? 0, 60)
    }

    func testTheRuleHoldsOnADayStillInProgress() {
        // The app decodes today before sleep detection has run for it: nothing outside a logged sleep session
        // is known to be awake. That must not turn a desk session into "no claim" and silence the reminder.
        let seated = decoded(liveDay: true) { $0.desk(3_000) }
        let a = decide(seated.runs, steps: seated.steps, now: seated.end)
        XCTAssertEqual(a.reason, .remind, "\(String(describing: a.window))")

        let walked = decoded(liveDay: true) { $0.desk(1_500); $0.walk(90); $0.desk(1_410) }
        let b = decide(walked.runs, steps: walked.steps, now: walked.end)
        XCTAssertEqual(b.reason, .movedEnough, "\(String(describing: b.window))")

        let brief = decoded(liveDay: true) { $0.desk(1_500); $0.walk(15); $0.desk(1_485) }
        let c = decide(brief.runs, steps: brief.steps, now: brief.end)
        XCTAssertEqual(c.reason, .remind, "fifteen seconds is not a minute: \(String(describing: c.window))")
    }

    func testADecodedWorkdayOfBriefWalksStaysQuiet() {
        // A walk to the kettle every ten minutes: nine 20-second walks in the hour.
        let day = decoded { sim in
            for _ in 0..<6 { sim.desk(540); sim.walk(25) }
        }
        let d = decide(day.runs, steps: day.steps, now: day.end)
        XCTAssertEqual(d.reason, .movedEnough, "\(String(describing: d.window))")
    }

    func testStepTicksComeFromTheCounterTheWayTheDecoderReadsIt() {
        let samples = [
            StepSample(ts: noon, counter: 100),
            StepSample(ts: noon + 1, counter: 103),
            StepSample(ts: noon + 2, counter: 103),
            StepSample(ts: noon + 3, counter: 110),
            StepSample(ts: noon + 100, counter: 150),
            StepSample(ts: noon + 101, counter: 0xFFFF),
            StepSample(ts: noon + 102, counter: 2),
        ]
        let all = StandReminderEngine.stepTicks(from: samples, start: noon, end: noon + 200)
        XCTAssertEqual(all.map(\.ts), [noon + 1, noon + 3, noon + 102])
        XCTAssertEqual(all.map(\.ticks), [3, StepsCounter.maxTicksPerSecond, 3],
                       "a burst is capped at the gait ceiling; a gap, a reboot-sized jump and a still second add nothing; a wrap counts")
        let inner = StandReminderEngine.stepTicks(from: samples, start: noon + 2, end: noon + 4)
        XCTAssertEqual(inner.map(\.ts), [noon + 3], "only the window's own seconds, differenced against the sample before it")
        let backwards = Array(samples.reversed())
        XCTAssertTrue(StandReminderEngine.stepTicks(from: backwards, start: noon, end: noon).isEmpty)
        XCTAssertEqual(StandReminderEngine.stepTicks(from: backwards, start: noon, end: noon + 200).map(\.ts),
                       all.map(\.ts), "input order does not matter")
    }
}
