import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HRVWindowTests: XCTestCase {
    private let t0 = 1_760_000_000

    /// Beats at a constant interval, timestamped beat-accurately (`ts` advances by `ms`/1000 each beat,
    /// matching the convention `ActivityContextIntervalTests.rsa` uses) so the trust gates pass.
    private func beats(constantMs: Double, from: Int, seconds: Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        let end = Double(from + seconds)
        while t < end {
            out.append(RRInterval(ts: Int(t), rrMs: Int(constantMs)))
            t += constantMs / 1000.0
        }
        return out
    }

    /// A slow linear drift: tiny successive differences (low RMSSD) but a wide overall range (high SDNN),
    /// proving the two are computed independently rather than one derived from the other.
    private func drifting(from: Int, beatCount: Int, startMs: Double = 700, stepMs: Double = 2) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        for k in 0..<beatCount {
            let rr = startMs + stepMs * Double(k)
            out.append(RRInterval(ts: Int(t), rrMs: Int(rr)))
            t += rr / 1000.0
        }
        return out
    }

    private func interval(_ s: Int, _ e: Int, _ c: ActivityClass, sleep: SleepContextState = .awake,
                          wear: WearContextState = .onWrist) -> ActivityContextInterval {
        ActivityContextInterval(start: s, end: e, activityClass: c, confidence: 0.9, sleep: sleep, wear: wear)
    }

    /// Awake, on-wrist sitting over a wide span: the decoded context a resting-eligible window needs.
    private func awakeSitting(_ from: Int, _ to: Int) -> ActivityContextLookup {
        ActivityContextLookup(intervals: [interval(from, to, .sitting)])
    }

    // MARK: Canonical windowing

    func testCanonicalWindowingTilesTheSpanAndDropsATrailingPartial() {
        let rr = beats(constantMs: 800, from: t0, seconds: 720) // 12 minutes of data
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 720, rr: rr)
        XCTAssertEqual(windows.count, 2, "two full 5-min windows; the trailing 120 s is not a canonical window")
        XCTAssertEqual(windows.map(\.start), [t0, t0 + 300])
        XCTAssertEqual(windows.map(\.end), [t0 + 300, t0 + 600])
        XCTAssertTrue(windows.allSatisfy { $0.durationSeconds == 300 })
    }

    func testNoRRDataMeansNoWindowEmitted() {
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: [])
        XCTAssertTrue(windows.isEmpty, "never invent an observation where there is no R-R data")
    }

    func testThreeKindsHaveDistinctCanonicalDurations() {
        XCTAssertEqual(HRVWindowKind.canonical5m.durationSeconds, 300)
        XCTAssertEqual(HRVWindowKind.secondary2m.durationSeconds, 120)
        XCTAssertEqual(HRVWindowKind.exploratory1m.durationSeconds, 60)
    }

    // MARK: RMSSD / SDNN independence

    func testRmssdAndSdnnAreComputedIndependently() throws {
        let rr = drifting(from: t0, beatCount: 150)
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr)
        let w = try XCTUnwrap(windows.first)
        let rmssd = try XCTUnwrap(w.rmssd)
        let sdnn = try XCTUnwrap(w.sdnn)
        XCTAssertLessThan(rmssd, 10, "tiny constant successive differences")
        XCTAssertGreaterThan(sdnn, 50, "a wide linear drift spreads the whole-window SD, unlike RMSSD")
        XCTAssertGreaterThan(sdnn, rmssd * 5, "SDNN must not be a scaled copy of RMSSD")
    }

    func testMeanAndMedianNNAreReportedBesideRmssdAndSdnn() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertEqual(try XCTUnwrap(w.meanNN), 800, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(w.medianNN), 800, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(w.rmssd), 0, accuracy: 1e-6, "no variation at all between constant beats")
    }

    // MARK: Never a cross-window difference

    func testNoDifferenceIsEverFormedAcrossAWindowBoundary() throws {
        // Each window is internally dead flat (rmssd 0), but the LAST beat of window 1 and the FIRST beat
        // of window 2 are set to a huge, deliberately mismatched pair. If a diff were ever taken across
        // the window boundary, both windows' rmssd would spike; because each window is sliced and cleaned
        // from ITS OWN beats only, neither does.
        var rr = beats(constantMs: 800, from: t0, seconds: 300)
        rr[rr.count - 1] = RRInterval(ts: rr[rr.count - 1].ts, rrMs: 1_400)
        var rr2 = beats(constantMs: 800, from: t0 + 300, seconds: 300)
        rr2[0] = RRInterval(ts: rr2[0].ts, rrMs: 300)
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 600, rr: rr + rr2)
        XCTAssertEqual(windows.count, 2)
        for w in windows {
            XCTAssertLessThan(try XCTUnwrap(w.rmssd), 50,
                              "a cross-window splice would read in the hundreds of ms; neither window saw one")
        }
    }

    // MARK: Motion

    func testMotionRmsPrefersImuWindowsOverGravityFallback() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let imu = [ImuWindowFeatures(startTs: t0, endTs: t0 + 300, accelRmsG: 0.05, gyroRmsDps: 3, jerkRms: 0,
                                     cadenceHz: nil, cadenceStrength: 0)]
        let gravity = (0..<300).map { GravitySample(ts: t0 + $0, x: 0, y: 0, z: 1, dynAccel: 0.5) }
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      imuWindows: imu, gravity: gravity).first)
        XCTAssertEqual(try XCTUnwrap(w.motionRmsG), 0.05, accuracy: 1e-9, "IMU window features take priority")
        XCTAssertEqual(try XCTUnwrap(w.gyroRmsDps), 3, accuracy: 1e-9)
    }

    func testMotionRmsFallsBackToGravityDynAccelWhenNoImuWindowOverlaps() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let gravity = (0..<300).map { GravitySample(ts: t0 + $0, x: 0, y: 0, z: 1, dynAccel: 0.02) }
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      gravity: gravity).first)
        XCTAssertEqual(try XCTUnwrap(w.motionRmsG), 0.02, accuracy: 1e-9)
        XCTAssertNil(w.gyroRmsDps, "no 1 Hz gyro stream to fall back to")
    }

    func testMotionIsNilNotZeroWithoutAnyMotionStream() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertNil(w.motionRmsG, "absence of a motion reading is not evidence of stillness")
        XCTAssertNil(w.gyroRmsDps)
    }

    // MARK: Activity-context join and lookback (metadata, not a gate)

    func testActivityContextIsTheCoverageWeightedDominantClassAndItsShare() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let lookup = ActivityContextLookup(intervals: [
            interval(t0, t0 + 200, .sitting), interval(t0 + 200, t0 + 300, .walking),
        ])
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: lookup).first)
        XCTAssertEqual(w.activityContext, .sitting)
        XCTAssertEqual(try XCTUnwrap(w.activityConfidence), 200.0 / 300.0, accuracy: 1e-9)
    }

    func testSecondsSinceLocomotionAndExerciseLookBackThroughTheActivityLookup() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let lookup = ActivityContextLookup(intervals: [
            interval(t0 - 500, t0 - 50, .walking),
            interval(t0 - 1_000, t0 - 800, .vigorousActivity),
        ])
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: lookup).first)
        // Measured from the window START (t0): a walk that ended inside the window, or just before it,
        // must not look further away because the window ran on after it (D3-03).
        XCTAssertEqual(w.secondsSinceLocomotion, t0 - (t0 - 50))
        XCTAssertEqual(w.secondsSinceExercise, t0 - (t0 - 800))
    }

    func testLocomotionOverlappingTheWindowReadsZero() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let lookup = ActivityContextLookup(intervals: [
            interval(t0 - 100, t0 + 100, .walking), interval(t0 + 100, t0 + 300, .sitting),
        ])
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: lookup, transitionEvents: []).first)
        XCTAssertEqual(w.secondsSinceLocomotion, 0)
        XCTAssertFalse(w.eligibleForBaseline, "a walk inside the window is not resting physiology")
    }

    func testNoActivityLookupLeavesContextFieldsNilRatherThanGuessing() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertNil(w.activityContext)
        XCTAssertNil(w.activityConfidence)
        XCTAssertNil(w.secondsSinceLocomotion)
        XCTAssertNil(w.secondsSinceExercise)
        XCTAssertNil(w.asleep, "no lookup: sleep is unknown, not awake")
        XCTAssertNil(w.wear, "no lookup: wear is unknown, not on-wrist")
        XCTAssertFalse(w.eligibleForBaseline)
    }

    // MARK: Transition / recovery / steady-state

    func testPhaseAndEligibilityThroughATransitionsWake() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 10_000)
        let transitionTs = t0 + 500
        let events = [ActivityTransitionEvent(kind: .standToSitLike, probability: 0.9, ts: transitionTs)]
        let lookup = awakeSitting(t0 - 1_000, t0 + 11_000)

        func window(startOffset: Int) throws -> HRVWindow {
            let start = t0 + startOffset
            return try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: start, dayEnd: start + 300,
                                                        rr: rr, activity: lookup, transitionEvents: events).first)
        }

        // Window STARTING 10 s after the transition: deep inside the transition guard.
        let justAfter = try window(startOffset: 500 + 10)
        XCTAssertEqual(justAfter.phase, .transition)
        XCTAssertEqual(justAfter.secondsSinceTransition, 10)
        XCTAssertFalse(justAfter.eligibleForBaseline)

        // Window starting 60 s after: past the 30 s transition guard, inside the 120 s recovery guard.
        let recovering = try window(startOffset: 500 + 60)
        XCTAssertEqual(recovering.phase, .recovery)
        XCTAssertFalse(recovering.eligibleForBaseline, "recovery is real physiology, but not a baseline observation")

        // Window starting 200 s after: past both guards.
        let steady = try window(startOffset: 500 + 200)
        XCTAssertEqual(steady.phase, .steadyState)
        XCTAssertEqual(steady.transitionsInWindow, 0)
        XCTAssertTrue(steady.eligibleForBaseline)
    }

    func testTransitionInsideTheWindowIsNeverSteadyState() throws {
        // D3-03: [t, t+300) with a stand-up at t+100. Measured from the window END this read 200 s →
        // steadyState and eligible, although 100 s of the RMSSD is seated and 200 s standing.
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let events = [ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.8, ts: t0 + 100)]
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: awakeSitting(t0 - 600, t0 + 600),
                                                      transitionEvents: events).first)
        XCTAssertEqual(w.transitionsInWindow, 1)
        XCTAssertEqual(w.secondsSinceTransition, 0, "a transition inside the window is 0 s away")
        XCTAssertEqual(w.phase, .transition)
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testTransitionBeforeTheWindowStartIsRecovery() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let events = [ActivityTransitionEvent(kind: .standToSitLike, probability: 0.8, ts: t0 - 60)]
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: awakeSitting(t0 - 600, t0 + 600),
                                                      transitionEvents: events).first)
        XCTAssertEqual(w.transitionsInWindow, 0)
        XCTAssertEqual(w.secondsSinceTransition, 60)
        XCTAssertEqual(w.phase, .recovery)
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testEventFlaggedJustAfterTheWindowEndCountsAsInsideIt() throws {
        // The causal decoder flags a transition a few seconds after its onset; one flagged 3 s after the
        // window end began inside it.
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let events = [ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.8, ts: t0 + 303)]
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: awakeSitting(t0 - 600, t0 + 600),
                                                      transitionEvents: events).first)
        XCTAssertEqual(w.transitionsInWindow, 1)
        XCTAssertEqual(w.phase, .transition)
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testPosturalAndLocomotionSecondsSinceAreSeparate() throws {
        // D2-16: events [walk_stop@0, stand_to_sit@170], window start 200.
        let start = t0 + 200
        let rr = beats(constantMs: 800, from: start, seconds: 300)
        let events = [ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: t0),
                      ActivityTransitionEvent(kind: .standToSitLike, probability: 0.7, ts: t0 + 170)]
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: start, dayEnd: start + 300,
                                                      rr: rr, activity: awakeSitting(t0 - 600, t0 + 1_000),
                                                      transitionEvents: events).first)
        XCTAssertEqual(w.secondsSincePosturalTransition, 30)
        XCTAssertEqual(w.secondsSinceLocomotionTransition, 200)
        XCTAssertEqual(w.secondsSinceTransition, 30, "the combined value is the nearer of the two")
        XCTAssertEqual(w.phase, .recovery, "30 s after the stand-to-sit: settling, not steady")
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testDecodedSpanWithNoTransitionsReadsSteadyState() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: awakeSitting(t0 - 600, t0 + 600),
                                                      transitionEvents: []).first)
        XCTAssertNil(w.secondsSinceTransition)
        XCTAssertTrue(w.transitionEventsAvailable)
        XCTAssertEqual(w.phase, .steadyState, "absence of a transition event is not evidence one just happened")
        XCTAssertEqual(w.asleep, false)
        XCTAssertEqual(w.wear, .onWrist)
        XCTAssertTrue(w.eligibleForBaseline)
    }

    func testNoEventDataIsUnknownPhaseNotSteadyState() throws {
        // D6-03 correction: "no events in the lookback" (above) is not "no event data available".
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: awakeSitting(t0 - 600, t0 + 600)).first)
        XCTAssertFalse(w.transitionEventsAvailable)
        XCTAssertEqual(w.phase, .unknown)
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testAsleepWindowIsNotAnAwakeBaselineObservation() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let asleepLookup = ActivityContextLookup(intervals: [interval(t0 - 600, t0 + 600, .sleeping, sleep: .asleep)])
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: asleepLookup, transitionEvents: []).first)
        XCTAssertEqual(w.asleep, true)
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testUnknownSleepOrMostlyUncoveredWindowIsNotKnownAwake() throws {
        // Review fix: `asleep` used to be false whenever nothing was EXPLICITLY asleep, so a lookup with
        // `sleep == .unknown` (the live day) or a window the lookup barely covers read known-awake.
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let unknownSleep = ActivityContextLookup(intervals: [interval(t0 - 600, t0 + 600, .sitting, sleep: .unknown)])
        let w1 = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                       activity: unknownSleep, transitionEvents: []).first)
        XCTAssertNil(w1.asleep, "sleep == .unknown is not evidence of being awake")
        XCTAssertEqual(w1.wear, .onWrist)
        XCTAssertFalse(w1.eligibleForBaseline)

        // On-wrist over the whole window, but explicitly awake over only 100 of its 300 s.
        let partlyAwake = ActivityContextLookup(intervals: [interval(t0, t0 + 100, .sitting, sleep: .awake),
                                                            interval(t0 + 100, t0 + 300, .sitting, sleep: .unknown)])
        let w2 = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                       activity: partlyAwake, transitionEvents: []).first)
        XCTAssertNil(w2.asleep)
        XCTAssertFalse(w2.eligibleForBaseline)

        // Explicitly awake over exactly half the window is known awake (same boundary as wear).
        let halfAwake = ActivityContextLookup(intervals: [interval(t0, t0 + 150, .sitting, sleep: .awake),
                                                          interval(t0 + 150, t0 + 300, .sitting, sleep: .unknown)])
        let w3 = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                       activity: halfAwake, transitionEvents: []).first)
        XCTAssertEqual(w3.asleep, false)
        XCTAssertTrue(w3.eligibleForBaseline)
    }

    func testHandBuiltWindowWithoutContextArgumentsIsNotEligible() {
        // Review fix: the init used to default to the most permissive context (events available, awake,
        // on-wrist), so a window built by hand without them passed the context gates.
        let w = HRVWindow(kind: .canonical5m, start: t0, end: t0 + 300, rmssd: 30, sdnn: 40, meanNN: 800,
                          medianNN: 800, rrDiffSqSumMs2: 1_000, rrDiffCount: 100, nnM2: 2_000, validRRCount: 300,
                          artifactFraction: 0.05,
                          signalQuality: HRVSignalQuality(coverageVerdict: .plausible, beatAccurateFraction: 0.99,
                                                          trustworthy: true),
                          motionRmsG: 0.01, gyroRmsDps: nil, activityContext: .sitting, activityConfidence: 0.9,
                          secondsSinceTransition: 300, secondsSinceLocomotion: nil, secondsSinceExercise: nil,
                          phase: .steadyState, eligibleForBaseline: false)
        XCTAssertFalse(w.transitionEventsAvailable)
        XCTAssertNil(w.asleep)
        XCTAssertNil(w.wear)
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w))
    }

    func testUnknownOrOffWristWearIsNotEligible() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let unknownWear = ActivityContextLookup(intervals: [interval(t0 - 600, t0 + 600, .stationary, wear: .unknown)])
        let w1 = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                       activity: unknownWear, transitionEvents: []).first)
        XCTAssertEqual(w1.wear, .unknown)
        XCTAssertFalse(w1.eligibleForBaseline)

        // Mostly uncovered by the lookup (decoder gap): wear not known for most of the window.
        let thin = awakeSitting(t0, t0 + 100)
        let w2 = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                       activity: thin, transitionEvents: []).first)
        XCTAssertEqual(w2.wear, .unknown)
        XCTAssertFalse(w2.eligibleForBaseline)

        let off = ActivityContextLookup(intervals: [interval(t0, t0 + 250, .sitting),
                                                    interval(t0 + 250, t0 + 300, .offWrist, wear: .offWrist)])
        let w3 = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                       activity: off, transitionEvents: []).first)
        XCTAssertEqual(w3.wear, .offWrist)
        XCTAssertFalse(w3.eligibleForBaseline)
    }

    func testTooSoonAfterLocomotionOrExerciseIsNotEligible() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        func window(_ intervals: [ActivityContextInterval]) throws -> HRVWindow {
            try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                 activity: ActivityContextLookup(intervals: intervals),
                                                 transitionEvents: []).first)
        }
        // Walk ended 100 s before the window: under the 300 s locomotion floor.
        let recentWalk = try window([interval(t0 - 400, t0 - 100, .walking), interval(t0 - 100, t0 + 600, .sitting)])
        XCTAssertEqual(recentWalk.secondsSinceLocomotion, 100)
        XCTAssertFalse(recentWalk.eligibleForBaseline)
        // Walk ended 400 s before: settled.
        let oldWalk = try window([interval(t0 - 700, t0 - 400, .walking), interval(t0 - 400, t0 + 600, .sitting)])
        XCTAssertTrue(oldWalk.eligibleForBaseline)
        // Vigorous effort ended 400 s before: under the 600 s exercise floor.
        let recentEffort = try window([interval(t0 - 900, t0 - 400, .vigorousActivity),
                                       interval(t0 - 400, t0 + 600, .sitting)])
        XCTAssertEqual(recentEffort.secondsSinceExercise, 400)
        XCTAssertFalse(recentEffort.eligibleForBaseline)
    }

    func testWindowPhaseRules() {
        XCTAssertEqual(ActivityTransitionProximity.windowPhase(secondsSinceTransitionAtStart: nil,
                                                               transitionsInWindow: 0, eventsAvailable: false), .unknown)
        XCTAssertEqual(ActivityTransitionProximity.windowPhase(secondsSinceTransitionAtStart: nil,
                                                               transitionsInWindow: 0, eventsAvailable: true), .steadyState)
        XCTAssertEqual(ActivityTransitionProximity.windowPhase(secondsSinceTransitionAtStart: 500,
                                                               transitionsInWindow: 1, eventsAvailable: true), .transition)
        // The moment-level convention is unchanged: nil is steady state.
        XCTAssertEqual(ActivityTransitionProximity.phase(secondsSinceTransition: nil), .steadyState)
        XCTAssertTrue(ActivityTransitionProximity.isPostural(.lyingDownLike))
        XCTAssertFalse(ActivityTransitionProximity.isPostural(.walkStop))
    }

    // MARK: Eligibility is motion/quality-gated, not semantic-class-gated

    private func baseEligibleWindow(activityContext: ActivityClass? = .sitting, motionRmsG: Double? = 0.01,
                                    gyroRmsDps: Double? = nil, artifactFraction: Double? = 0.05,
                                    phase: ActivityPhysiologyPhase = .steadyState, rmssd: Double? = 30,
                                    trustworthy: Bool = true) -> HRVWindow {
        HRVWindow(kind: .canonical5m, start: t0, end: t0 + 300, rmssd: rmssd, sdnn: 40, meanNN: 800,
                 medianNN: 800, rrDiffSqSumMs2: 1_000, rrDiffCount: 100, nnM2: 2_000, validRRCount: 300,
                 artifactFraction: artifactFraction,
                 signalQuality: HRVSignalQuality(coverageVerdict: .plausible, beatAccurateFraction: 0.99,
                                                 trustworthy: trustworthy),
                 motionRmsG: motionRmsG, gyroRmsDps: gyroRmsDps, activityContext: activityContext,
                 activityConfidence: 0.9, secondsSinceTransition: 300, secondsSinceLocomotion: nil,
                 secondsSinceExercise: nil, phase: phase, eligibleForBaseline: false,
                 transitionEventsAvailable: true, asleep: false, wear: .onWrist)
    }

    func testEligibilityPassesOnCleanSteadyStateMotion() {
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow()))
    }

    func testEligibilityDoesNotCareWhichNonOffWristClassIsAttached() {
        // The whole point of the item-D fix: a `walking` or `lightActivity` LABEL does not by itself
        // decide trust. A clean, steady, low-motion window reads eligible under either label.
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(activityContext: .walking)))
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(activityContext: .lightActivity)))
    }

    func testEligibilityFailsOffWristRegardlessOfEverythingElse() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(activityContext: .offWrist)))
    }

    func testEligibilityFailsWithoutRmssd() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(rmssd: nil)))
    }

    func testEligibilityFailsWhenNotSteadyState() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(phase: .transition)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(phase: .recovery)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(phase: .unknown)))
    }

    func testEligibilityFailsOnHandBuiltContextGates() {
        var w = baseEligibleWindow(); w.transitionsInWindow = 1
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "a transition inside the window")
        w = baseEligibleWindow(); w.transitionEventsAvailable = false
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "no event data")
        w = baseEligibleWindow(); w.asleep = true
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "asleep")
        w = baseEligibleWindow(); w.asleep = nil
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "sleep unknown")
        w = baseEligibleWindow(); w.wear = .unknown
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "wear unknown")
        w.wearSignal = .onWristGood
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(w), "a good wear signal makes wear known")
        w = baseEligibleWindow(); w.secondsSinceLocomotion = 60
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "a minute after walking")
        w = baseEligibleWindow(); w.secondsSinceExercise = 300
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(w), "five minutes after vigorous effort")
    }

    func testEligibilityFailsOnHighMotionOrGyroEvenUnderAStillLabel() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(activityContext: .sitting, motionRmsG: 0.5)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(activityContext: .sitting, gyroRmsDps: 50)))
    }

    func testEligibilityIsNotPenalizedByAbsentMotionReadings() {
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(motionRmsG: nil, gyroRmsDps: nil)))
    }

    func testEligibilityFailsOnHighArtifactFractionOrUntrustworthySignal() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(artifactFraction: 0.9)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(trustworthy: false)))
    }

    // MARK: Diagnostic summary

    func testDiagLineReportsCountsAndMeansOverEligibleWindowsOnly() {
        var eligible = baseEligibleWindow(motionRmsG: 0.01)
        eligible.eligibleForBaseline = HRVWindowBuilder.isEligibleForBaseline(eligible)
        var ineligible = baseEligibleWindow(phase: .transition)
        ineligible.eligibleForBaseline = HRVWindowBuilder.isEligibleForBaseline(ineligible)
        ineligible.rmssd = 999 // must not leak into the eligible-only means
        let line = HRVWindowSummary.diagLine([eligible, ineligible], kind: .canonical5m, day: "2026-10-05")
        XCTAssertTrue(line.contains("2 canonical_5m windows"))
        XCTAssertTrue(line.contains("1 eligible for baseline"))
        XCTAssertTrue(line.contains("mean rmssd 30.0 ms"), line)
        XCTAssertFalse(line.contains("999"))
        XCTAssertTrue(line.contains("motion data 2/2"))
        XCTAssertTrue(line.contains("gyro data 0/2"))
    }

    func testDiagLineHandlesNoWindowsAndNoEligibleWindows() {
        XCTAssertEqual(HRVWindowSummary.diagLine([], kind: .canonical5m, day: "2026-10-05"),
                       "HRV windows for 2026-10-05: no canonical_5m windows (no R-R data)")
        var ineligible = baseEligibleWindow(phase: .transition)
        ineligible.eligibleForBaseline = HRVWindowBuilder.isEligibleForBaseline(ineligible)
        let allIneligible = [ineligible]
        let line = HRVWindowSummary.diagLine(allIneligible, kind: .canonical5m, day: "2026-10-05")
        XCTAssertTrue(line.contains("0 eligible for baseline"))
        XCTAssertFalse(line.contains("mean rmssd"), "no eligible windows means no mean to report")
    }
}
