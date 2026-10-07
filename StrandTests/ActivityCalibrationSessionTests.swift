import XCTest
@testable import Strand
@testable import StrandAnalytics

/// Guided activity ground-truth capture: the durable restore marker plus the pure, closure-driven
/// session state machine. No BLE anywhere — the gate, mode application, haptics and clock are all
/// injected, so the full protocol runs here against a fake clock.
final class ActivityCalibrationSessionTests: XCTestCase {

    /// Fixed fake-clock epoch (2023-11-14T22:13:20Z). All bout timestamps are unix seconds off it.
    private let epoch = 1_700_000_000

    // MARK: - Fixtures

    private func task(id: String = "sit-quiet",
                      duration: Int = 10, reps: Int = 1, rest: Int = 2, guardSeconds: Int = 2,
                      posture: String? = "seated_likely", locomotion: String? = nil,
                      armBehavior: String? = nil, semanticTag: String? = nil,
                      transitionKind: String? = nil, preState: Int? = nil,
                      postState: Int? = nil) -> ActivityCalibrationTask {
        ActivityCalibrationTask(id: id, title: id, instructions: "Follow the prompt", category: "posture",
                                posture: posture, locomotion: locomotion, armBehavior: armBehavior,
                                semanticTag: semanticTag, transitionKind: transitionKind,
                                durationSeconds: duration, repetitions: reps, restSeconds: rest,
                                preStateSeconds: preState, postStateSeconds: postState,
                                guardSeconds: guardSeconds)
    }

    private func model(_ tasks: [ActivityCalibrationTask],
                       version: String = "calibration-v1") -> ActivityCalibrationProtocolModel {
        ActivityCalibrationProtocolModel(version: version, tasks: tasks)
    }

    @MainActor
    private func makeHarness(_ tasks: [ActivityCalibrationTask],
                             deviceId: String? = "whoop-MG-TEST") throws -> Harness {
        let name = "activity-calibration-tests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return Harness(model: model(tasks), deviceId: deviceId, defaults: suite)
    }

    /// Mutable fake strap/clock state captured by the runner's injected closures. Kept as its
    /// own box so the closures never capture `self` (which Swift forbids before a stored
    /// property like `runner` is initialized).
    @MainActor
    private final class FakeStrap {
        var clock: Date
        var appliedModes: [ActivityImuCaptureMode] = []
        var hapticCount = 0
        var gateStatus: ActivityCalibrationSessionRunner.GateStatus = .ready
        var bouts: [ActivityCalibrationBout] = []
        init() {
            clock = Date(timeIntervalSince1970: 1_700_000_000)
        }
    }

    /// Drives one runner with a fake clock. `advance` moves the clock and ticks the machine.
    @MainActor
    private final class Harness {
        let strap: FakeStrap
        let runner: ActivityCalibrationSessionRunner
        let defaults: UserDefaults

        init(model: ActivityCalibrationProtocolModel, deviceId: String?, defaults: UserDefaults) {
            let strap = FakeStrap()
            self.strap = strap
            self.defaults = defaults
            runner = ActivityCalibrationSessionRunner(
                protocol: model, deviceId: deviceId,
                gate: { strap.gateStatus },
                applyMode: { strap.appliedModes.append($0) },
                haptic: { strap.hapticCount += 1 },
                now: { strap.clock },
                defaults: defaults)
            runner.onBout = { strap.bouts.append($0) }
        }

        func advance(_ seconds: Double) {
            strap.clock = strap.clock.addingTimeInterval(seconds)
            runner.tick()
        }
    }

    // MARK: - Restore marker

    func testMarkerBeginPendingClearRoundTrip() throws {
        let name = "activity-cal-marker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }

        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: defaults))
        ActivityCalibrationRestoreMarker.begin(previousMode: .partTime,
                                               now: Date(timeIntervalSince1970: 1_234),
                                               defaults: defaults)
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: defaults), .partTime)
        // Overwriting keeps the newest previous mode, like a relaunched session that restarted.
        ActivityCalibrationRestoreMarker.begin(previousMode: .continuous,
                                               now: Date(timeIntervalSince1970: 5_678),
                                               defaults: defaults)
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: defaults), .continuous)
        ActivityCalibrationRestoreMarker.clear(defaults: defaults)
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: defaults))
        // Garbage in the key reads as nil: safer to restore nothing than a mode we cannot name.
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: ActivityCalibrationRestoreMarker.key)
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: defaults))
    }

    func testRestoreIfPendingAppliesThePreviousModeExactlyOnce() throws {
        let name = "activity-cal-restore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }

        var applied: [ActivityImuCaptureMode] = []
        ActivityCalibrationRestoreMarker.begin(previousMode: .off, now: Date(timeIntervalSince1970: 9),
                                               defaults: defaults)
        XCTAssertTrue(ActivityCalibrationRestoreMarker.restoreIfPending(applyMode: { applied.append($0) },
                                                                        defaults: defaults))
        XCTAssertEqual(applied, [.off])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: defaults),
                     "a successful restore clears the marker")
        // Second call: nothing pending, nothing applied.
        XCTAssertFalse(ActivityCalibrationRestoreMarker.restoreIfPending(applyMode: { applied.append($0) },
                                                                         defaults: defaults))
        XCTAssertEqual(applied, [.off])
    }

    // MARK: - Full protocol run

    @MainActor
    func testBeginRunsASingleTaskProtocolEndToEnd() throws {
        let harness = try makeHarness([task(duration: 10, reps: 2, rest: 2)])
        let runner = harness.runner
        XCTAssertEqual(runner.phase, .idle)

        runner.begin(previousMode: .partTime)
        // Marker first, continuous forced, then the countdown.
        XCTAssertEqual(harness.strap.appliedModes, [.continuous])
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults), .partTime)
        guard case .countdown(let taskIndex, let endsAt) = runner.phase else {
            return XCTFail("expected countdown, got \(runner.phase)")
        }
        XCTAssertEqual(taskIndex, 0)
        XCTAssertEqual(endsAt.timeIntervalSince1970, TimeInterval(epoch + 3))

        // A tick before the countdown ends stays in countdown.
        harness.advance(2)
        guard case .countdown = runner.phase else { return XCTFail("countdown ended early: \(runner.phase)") }

        // Countdown ends -> start cue + active with the guarded interval recorded.
        harness.advance(1)
        guard case .active(let activeTask, let rep, let cueStart) = runner.phase else {
            return XCTFail("expected active, got \(runner.phase)")
        }
        XCTAssertEqual(activeTask, 0)
        XCTAssertEqual(rep, 0)
        XCTAssertEqual(cueStart, epoch + 3)
        XCTAssertEqual(harness.strap.hapticCount, 1)

        // Mid-bout ticks stay active until the stop cue.
        harness.advance(7)
        guard case .active = runner.phase else { return XCTFail("active ended early: \(runner.phase)") }

        // Stop cue -> bout (after cueStop, so timestamps are final) -> rest.
        harness.advance(3)
        guard case .rest(let restTask, let restRep, let restEndsAt) = runner.phase else {
            return XCTFail("expected rest, got \(runner.phase)")
        }
        XCTAssertEqual(harness.strap.hapticCount, 2)
        XCTAssertEqual(restTask, 0)
        XCTAssertEqual(restRep, 0)
        XCTAssertEqual(restEndsAt.timeIntervalSince1970, TimeInterval(epoch + 15))
        XCTAssertEqual(harness.strap.bouts.count, 1)
        let first = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertEqual(first.repetition, 1)
        XCTAssertEqual(first.taskId, "sit-quiet")
        XCTAssertEqual(first.instructionTs, epoch)
        XCTAssertEqual(first.countdownStartTs, epoch)
        XCTAssertEqual(first.cueStartTs, epoch + 3)
        XCTAssertEqual(first.cueStopTs, epoch + 13)
        XCTAssertEqual(first.intervalStartTs, first.cueStartTs + 2, "interval starts after the guard")
        XCTAssertEqual(first.intervalEndTs, first.cueStopTs - 2, "interval ends before the stop cue")
        XCTAssertGreaterThan(first.intervalEndTs, first.intervalStartTs)
        XCTAssertEqual(first.posture, "seated_likely")
        XCTAssertEqual(first.protocolVersion, "calibration-v1")

        // Rest over -> gate still ready -> second repetition's countdown and active.
        harness.advance(2)
        guard case .countdown = runner.phase else { return XCTFail("expected second countdown, got \(runner.phase)") }
        harness.advance(3)
        guard case .active(_, 1, let cue2) = runner.phase else {
            return XCTFail("expected second active, got \(runner.phase)")
        }
        XCTAssertEqual(cue2, epoch + 18)

        // Second bout is the last: the runner finishes, restores the previous mode and clears
        // the marker so nothing stays forced.
        harness.advance(10)
        XCTAssertEqual(runner.phase, .finished)
        XCTAssertEqual(harness.strap.bouts.count, 2)
        XCTAssertEqual(harness.strap.bouts[1].repetition, 2)
        XCTAssertEqual(harness.strap.bouts[1].cueStartTs, epoch + 18)
        XCTAssertEqual(harness.strap.bouts[1].cueStopTs, epoch + 28)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime],
                       "continuous was forced, then the previous mode was restored")
        XCTAssertEqual(harness.strap.hapticCount, 4, "start + stop for each bout, no extra cues")
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    // MARK: - Cancel / finish

    @MainActor
    func testCancelMidActiveRestoresThePreviousModeAndClearsTheMarker() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)
        guard case .active = harness.runner.phase else { return XCTFail("expected active") }

        harness.runner.cancel()
        XCTAssertEqual(harness.runner.phase, .cancelled)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
        XCTAssertEqual(harness.strap.bouts.count, 0, "a mid-capture bout is not emitted")
    }

    @MainActor
    func testCancelAfterCancelIsANoOp() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)
        harness.runner.cancel()
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])

        harness.runner.cancel()
        XCTAssertEqual(harness.runner.phase, .cancelled)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime], "a second cancel restores nothing again")
    }

    @MainActor
    func testBeginWhileRunningIsANoOp() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1)])
        harness.runner.begin(previousMode: .partTime)
        let phaseAfterFirst = harness.runner.phase
        XCTAssertEqual(harness.strap.appliedModes, [.continuous])

        // A second begin mid-flight must not restart the countdown or force the mode again.
        harness.runner.begin(previousMode: .continuous)
        XCTAssertEqual(harness.runner.phase, phaseAfterFirst)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous])
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults), .partTime,
                       "the first session's previous mode is still what the marker holds")
    }

    @MainActor
    func testBeginWithAnEmptyProtocolEndsCleanly() throws {
        let harness = try makeHarness([])
        harness.runner.begin(previousMode: .partTime)
        XCTAssertEqual(harness.runner.phase, .finished)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    // MARK: - Gate blocking

    @MainActor
    func testGateBlockedAtBeginRestoresAndClears() throws {
        let harness = try makeHarness([task()])
        harness.strap.gateStatus = .blocked(.batteryLow(pct: 12))
        harness.runner.begin(previousMode: .partTime)

        XCTAssertEqual(harness.runner.phase, .gate(.batteryLow(pct: 12)))
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime],
                       "continuous is applied, then the previous mode is put straight back")
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
        XCTAssertEqual(harness.strap.hapticCount, 0)
    }

    @MainActor
    func testGateBlockedMidSessionViaRefreshGateCancelsAndRestores() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)
        guard case .active = harness.runner.phase else { return XCTFail("expected active") }
        XCTAssertEqual(harness.strap.appliedModes, [.continuous])

        harness.strap.gateStatus = .blocked(.rawSessionInFlight)
        harness.runner.refreshGate()

        XCTAssertEqual(harness.runner.phase, .gate(.rawSessionInFlight))
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
        XCTAssertEqual(harness.strap.bouts.count, 0)
    }

    @MainActor
    func testGateBlockedBetweenRepetitionsStopsBeforeTheNextBout() throws {
        let harness = try makeHarness([task(duration: 10, reps: 2, rest: 2)])
        harness.runner.begin(previousMode: .off)
        harness.advance(3)    // bout 1 active
        harness.advance(10)   // bout 1 done -> rest
        XCTAssertEqual(harness.strap.bouts.count, 1)

        harness.strap.gateStatus = .blocked(.whoopNotConnected)
        harness.advance(2)    // rest over -> the between-bouts gate check fails

        XCTAssertEqual(harness.runner.phase, .gate(.whoopNotConnected))
        XCTAssertEqual(harness.strap.bouts.count, 1, "the blocked session never started bout 2")
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .off])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    // MARK: - Transitions

    @MainActor
    func testTransitionTaskEmitsATransitionWithinTheGuardedInterval() throws {
        // pre 5 s hold + post 5 s hold, 2 s guard each side.
        let harness = try makeHarness([task(duration: 10, reps: 1, guardSeconds: 2,
                                           transitionKind: "sit_to_stand", preState: 5, postState: 5)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)    // active at epoch+3; cueStop = epoch+13
        XCTAssertEqual(harness.strap.hapticCount, 0, "a held pre-state starts silently")

        // Still inside the pre-state hold: no "do it now" cue.
        harness.advance(4)    // epoch+7, one second before the pre-state ends
        XCTAssertEqual(harness.strap.hapticCount, 0)
        XCTAssertNil(harness.strap.bouts.last?.transitionTs)

        // Pre-state over -> the runner auto-fires the "do it now" cue and records the moment.
        harness.advance(1)    // epoch+8 = cueStart + pre
        XCTAssertEqual(harness.strap.hapticCount, 1, "the only movement cue")
        XCTAssertEqual(harness.strap.bouts.count, 0, "the bout is only emitted at the stop cue")

        // Post-state hold runs to the stop cue; last bout finishes the session.
        harness.advance(5)    // epoch+13
        XCTAssertEqual(harness.runner.phase, .finished)
        XCTAssertEqual(harness.strap.hapticCount, 2, "do-it-now + stop")
        let bout = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertEqual(bout.transitionKind, "sit_to_stand")
        let transitionTs = try XCTUnwrap(bout.transitionTs)
        XCTAssertGreaterThanOrEqual(transitionTs, bout.intervalStartTs)
        XCTAssertLessThan(transitionTs, bout.intervalEndTs)
        XCTAssertEqual(transitionTs - bout.cueStartTs, 5, "pre-state seconds held before the transition")
        XCTAssertEqual(bout.cueStopTs - transitionTs, 5, "post-state seconds held after the transition")
    }

    @MainActor
    func testMarkTransitionNowRecordsTheTapMoment() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1, guardSeconds: 2,
                                           transitionKind: "stand_to_sit", preState: 5, postState: 5)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)    // active at epoch+3
        harness.advance(2)    // epoch+5, two seconds before the auto-fire
        harness.runner.markTransitionNow()
        XCTAssertEqual(harness.strap.hapticCount, 1, "the tap fires the do-it-now cue immediately")

        harness.advance(8)    // epoch+13, stop cue
        XCTAssertEqual(harness.runner.phase, .finished)
        let bout = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertEqual(bout.transitionKind, "stand_to_sit")
        XCTAssertEqual(bout.transitionTs, epoch + 5, "the recorded moment is the tap, not the deadline")
        XCTAssertEqual(harness.strap.hapticCount, 2)
    }

    @MainActor
    func testAnEarlyTransitionTapIsClampedToTheIntervalStart() throws {
        let harness = try makeHarness([task(duration: 20, reps: 1, guardSeconds: 2,
                                           transitionKind: "sit_to_stand", preState: 8, postState: 8)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)     // active at epoch+3, still inside the 2 s guard trim
        harness.runner.markTransitionNow()
        harness.advance(20)    // stop cue

        let bout = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertEqual(bout.transitionTs, bout.intervalStartTs)
    }

    @MainActor
    func testALateTransitionTapIsClampedToTheIntervalEnd() throws {
        // No pre-state, so nothing auto-fires and the tap is the only way to record the moment.
        let harness = try makeHarness([task(duration: 20, reps: 1, guardSeconds: 2,
                                           transitionKind: "sit_to_stand")])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)     // active at epoch+3; interval ends at epoch+21, stop cue at epoch+23
        harness.advance(19)    // epoch+22, inside the trailing guard trim
        harness.runner.markTransitionNow()
        harness.advance(1)     // stop cue

        let bout = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertEqual(bout.transitionTs, bout.intervalEndTs)
    }

    @MainActor
    func testMarkTransitionNowIsANoOpForNonTransitionTasks() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1)])
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)
        harness.runner.markTransitionNow()
        harness.advance(10)

        let bout = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertNil(bout.transitionKind)
        XCTAssertNil(bout.transitionTs)
        XCTAssertEqual(harness.strap.hapticCount, 2, "no do-it-now cue for a static task")
    }

    @MainActor
    func testOnBoutHandlerThatCancelsIsNotOverriddenByARestPhase() throws {
        let harness = try makeHarness([task(duration: 10, reps: 2, rest: 2)])
        // The UI's label path decides to stop the session at the moment a bout lands.
        harness.runner.onBout = { [weak harness] bout in
            harness?.strap.bouts.append(bout)
            harness?.runner.cancel()
        }
        harness.runner.begin(previousMode: .partTime)
        harness.advance(3)
        harness.advance(10)   // bout 1 ends -> the handler cancels inside endActive

        XCTAssertEqual(harness.runner.phase, .cancelled,
                       "the handler's cancel wins over the rest phase the runner would enter next")
        XCTAssertEqual(harness.strap.bouts.count, 1)
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    // MARK: - Relaunch recovery

    @MainActor
    func testMarkerSurvivesASimulatedRelaunch() throws {
        let harness = try makeHarness([task(duration: 10, reps: 1)])
        harness.runner.begin(previousMode: .off)
        harness.advance(1)    // mid-countdown when the app dies

        // A fresh runner over the same defaults (as after relaunch) sees the marker and restores.
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults), .off)
        var restored: [ActivityImuCaptureMode] = []
        XCTAssertTrue(ActivityCalibrationRestoreMarker.restoreIfPending(applyMode: { restored.append($0) },
                                                                        defaults: harness.defaults))
        XCTAssertEqual(restored, [.off])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }
}
