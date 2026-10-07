import XCTest
@testable import Strand
@testable import StrandAnalytics

/// Guided activity ground-truth capture: the durable restore marker plus the pure, closure-driven
/// session state machine. No BLE anywhere: the gate, mode application, haptics and clock are all
/// injected, so the full protocol runs here against a fake clock.
final class ActivityCalibrationSessionTests: XCTestCase {

    /// Fixed fake-clock epoch (2023-11-14T22:13:20Z). All bout timestamps are unix seconds off it.
    private let epoch = 1_700_000_000

    // MARK: - Fixtures

    private func hold(_ id: String, seconds: Int = 10, posture: String = "seated_likely") -> ActivityCalibrationTask {
        ActivityCalibrationTask(id: id, title: id, instructions: "Hold", posture: posture, durationSeconds: seconds)
    }

    private func move(_ id: String, seconds: Int = 10, cue: Int = 3) -> ActivityCalibrationTask {
        ActivityCalibrationTask(id: id, title: id, instructions: "Move", transitionKind: "sit_to_stand",
                                endPosture: "upright_stationary", durationSeconds: seconds, cueSeconds: cue)
    }

    /// Activity 0: hold 10, move 10 (buzz at +3), hold 10. Activity 1: hold 10.
    private func twoActivities() -> ActivityCalibrationProtocolModel {
        ActivityCalibrationProtocolModel(version: "calibration-test", activities: [
            ActivityCalibrationActivity(id: "a", title: "A", setup: "Setup A",
                                        tasks: [hold("a.hold-1"), move("a.move"), hold("a.hold-2", posture: "upright_stationary")]),
            ActivityCalibrationActivity(id: "b", title: "B", setup: "Setup B", tasks: [hold("b.hold")]),
        ])
    }

    @MainActor
    private func makeHarness(_ model: ActivityCalibrationProtocolModel? = nil) throws -> Harness {
        let name = "activity-calibration-tests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return Harness(model: model ?? twoActivities(), defaults: suite)
    }

    @MainActor
    private final class FakeStrap {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var appliedModes: [ActivityImuCaptureMode] = []
        var cues: [ActivityCalibrationSessionRunner.Cue] = []
        var gateStatus: ActivityCalibrationSessionRunner.GateStatus = .ready
        var bouts: [ActivityCalibrationBout] = []
    }

    /// Drives one runner with a fake clock. `advance` moves the clock and ticks the machine.
    @MainActor
    private final class Harness {
        let strap: FakeStrap
        let runner: ActivityCalibrationSessionRunner
        let defaults: UserDefaults

        init(model: ActivityCalibrationProtocolModel, defaults: UserDefaults) {
            let strap = FakeStrap()
            self.strap = strap
            self.defaults = defaults
            runner = ActivityCalibrationSessionRunner(
                protocol: model, deviceId: "whoop-MG-TEST",
                gate: { strap.gateStatus },
                applyMode: { strap.appliedModes.append($0) },
                haptic: { strap.cues.append($0) },
                now: { strap.clock },
                defaults: defaults)
            runner.onBout = { strap.bouts.append($0) }
        }

        func advance(_ seconds: Double) {
            strap.clock = strap.clock.addingTimeInterval(seconds)
            runner.tick()
        }

        /// begin, start, and run the 5 s start countdown so step 0 of activity 0 is recording.
        func startFirstActivity() {
            runner.begin(previousMode: .partTime)
            runner.start()
            advance(Double(ActivityCalibrationProtocols.startCountdownSeconds))
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
    func testBeginWaitsAtTheFirstActivityUntilStartIsTapped() throws {
        let harness = try makeHarness()
        XCTAssertEqual(harness.runner.phase, .idle)
        harness.runner.begin(previousMode: .partTime)

        XCTAssertEqual(harness.runner.phase, .ready(activity: 0))
        XCTAssertEqual(harness.strap.appliedModes, [.continuous])
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults), .partTime)
        harness.advance(60)
        XCTAssertEqual(harness.runner.phase, .ready(activity: 0), "nothing starts on its own")

        harness.runner.start()
        guard case .countdown(let activity, let endsAt) = harness.runner.phase else {
            return XCTFail("expected countdown, got \(harness.runner.phase)")
        }
        XCTAssertEqual(activity, 0)
        XCTAssertEqual(endsAt.timeIntervalSince1970, harness.strap.clock.timeIntervalSince1970 + 5)
    }

    @MainActor
    func testStepsChainBackToBackAndEveryActivityEndsWithDone() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        let t0 = epoch + 5
        guard case .step(let first) = harness.runner.phase else { return XCTFail("expected step") }
        XCTAssertEqual(first.task, 0)
        XCTAssertNil(first.cueAt, "holds never buzz")

        harness.advance(10)   // hold 1 ends, move starts on the same deadline
        guard case .step(let second) = harness.runner.phase else { return XCTFail("expected move step") }
        XCTAssertEqual(second.task, 1)
        XCTAssertEqual(second.startedAt.timeIntervalSince1970, TimeInterval(t0 + 10))
        XCTAssertEqual(harness.strap.bouts.count, 1)

        harness.advance(10)
        harness.advance(10)   // hold 2 ends -> activity 0 done
        XCTAssertEqual(harness.strap.bouts.map(\.taskId), ["a.hold-1", "a.move", "a.hold-2"])
        XCTAssertEqual(harness.runner.phase, .ready(activity: 1), "the next activity waits for its own Start")
        XCTAssertEqual(harness.strap.cues, [.move, .done])

        harness.runner.start()
        harness.advance(5)
        harness.advance(10)
        XCTAssertEqual(harness.runner.phase, .finished)
        XCTAssertEqual(harness.strap.cues, [.move, .done, .done])
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
        XCTAssertTrue(harness.runner.skipped.isEmpty)
    }

    @MainActor
    func testAMoveBuzzesExactlyOnceAtItsCueAndTheScreenFlipsInTheSameTick() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(10)   // move starts at epoch+15, buzz due epoch+18
        harness.advance(2.5)
        guard case .step(let before) = harness.runner.phase else { return XCTFail("expected step") }
        XCTAssertFalse(before.moved)
        XCTAssertEqual(harness.strap.cues, [])

        harness.advance(0.5)
        guard case .step(let after) = harness.runner.phase else { return XCTFail("expected step") }
        XCTAssertTrue(after.moved, "the published state says move in the tick the buzz fires")
        XCTAssertEqual(harness.strap.cues, [.move])

        harness.advance(3)
        XCTAssertEqual(harness.strap.cues, [.move], "no repeat buzz")

        harness.advance(4)    // move step over
        let bout = try XCTUnwrap(harness.strap.bouts.first { $0.taskId == "a.move" })
        let ts = try XCTUnwrap(bout.transitionTs)
        XCTAssertEqual(bout.transitionKind, "sit_to_stand")
        XCTAssertEqual(ts, epoch + 18)
        XCTAssertGreaterThanOrEqual(ts, bout.intervalStartTs)
        XCTAssertLessThanOrEqual(ts, bout.intervalEndTs)
        XCTAssertEqual(bout.cueTs, epoch + 18)
        XCTAssertEqual(bout.intervalStartTs, epoch + 17)
        XCTAssertEqual(bout.intervalEndTs, epoch + 23)
        XCTAssertNil(bout.posture)
    }

    @MainActor
    func testHoldBoutsAreGuardedAndCarryNoTransition() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(10)
        let bout = try XCTUnwrap(harness.strap.bouts.first)
        XCTAssertEqual(bout.taskId, "a.hold-1")
        XCTAssertEqual(bout.stepStartTs, epoch + 5)
        XCTAssertEqual(bout.stepEndTs, epoch + 15)
        XCTAssertEqual(bout.intervalStartTs, epoch + 7)
        XCTAssertEqual(bout.intervalEndTs, epoch + 13)
        XCTAssertEqual(bout.posture, "seated_likely")
        XCTAssertNil(bout.transitionTs)
        XCTAssertNil(bout.cueTs)
        XCTAssertEqual(bout.protocolVersion, "calibration-test")
    }

    @MainActor
    func testALateTickDoesNotShiftTheNextStepsCue() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(10.4)   // hold 1 noticed 0.4 s late
        guard case .step(let step) = harness.runner.phase else { return XCTFail("expected step") }
        XCTAssertEqual(step.startedAt.timeIntervalSince1970, TimeInterval(epoch + 15), "chains on the deadline")
        XCTAssertEqual(step.cueAt?.timeIntervalSince1970, TimeInterval(epoch + 18))
    }

    func testAStallStartsTheNextStepNowInsteadOfFiringItsCueEarly() {
        let deadline = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ActivityCalibrationSessionRunner.chainStart(deadline: deadline, now: Date(timeIntervalSince1970: 100.9)), deadline)
        let late = Date(timeIntervalSince1970: 105)
        XCTAssertEqual(ActivityCalibrationSessionRunner.chainStart(deadline: deadline, now: late), late)
    }

    // MARK: - Skip

    @MainActor
    func testSkipFromReadyMovesOnWithoutCuesOrLabels() throws {
        let harness = try makeHarness()
        harness.runner.begin(previousMode: .partTime)
        harness.runner.skip()
        XCTAssertEqual(harness.runner.phase, .ready(activity: 1))
        XCTAssertEqual(harness.runner.skipped, [0])
        XCTAssertTrue(harness.strap.cues.isEmpty)
        XCTAssertTrue(harness.strap.bouts.isEmpty)
        XCTAssertNotNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults),
                        "skipping does not end the session")
    }

    @MainActor
    func testSkipDuringTheCountdown() throws {
        let harness = try makeHarness()
        harness.runner.begin(previousMode: .partTime)
        harness.runner.start()
        harness.advance(2)
        harness.runner.skip()
        XCTAssertEqual(harness.runner.phase, .ready(activity: 1))
        harness.advance(10)
        XCTAssertEqual(harness.runner.phase, .ready(activity: 1), "the dropped countdown never starts a step")
    }

    @MainActor
    func testSkipMidStepKeepsEarlierBoutsDropsTheOneInProgress() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(10)   // hold 1 saved, move running
        harness.advance(5)    // move buzzed
        XCTAssertEqual(harness.strap.cues, [.move])
        harness.runner.skip()

        XCTAssertEqual(harness.strap.bouts.map(\.taskId), ["a.hold-1"])
        XCTAssertEqual(harness.runner.phase, .ready(activity: 1))
        XCTAssertEqual(harness.runner.skipped, [0])
        XCTAssertEqual(harness.strap.cues, [.move], "no done cue for a skipped activity")

        // The next activity is unaffected: its first step carries no stale transition time.
        harness.runner.start()
        harness.advance(5)
        harness.advance(10)
        XCTAssertEqual(harness.strap.bouts.last?.taskId, "b.hold")
        XCTAssertNil(harness.strap.bouts.last?.transitionTs)
        XCTAssertEqual(harness.runner.phase, .finished)
    }

    @MainActor
    func testSkippingTheLastActivityFinishesAndRestores() throws {
        let harness = try makeHarness()
        harness.runner.begin(previousMode: .partTime)
        harness.runner.skip()
        harness.runner.skip()
        XCTAssertEqual(harness.runner.phase, .finished)
        XCTAssertEqual(harness.runner.skipped, [0, 1])
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    @MainActor
    func testSkipAndStartAreNoOpsOutsideASession() throws {
        let harness = try makeHarness()
        harness.runner.skip()
        harness.runner.start()
        XCTAssertEqual(harness.runner.phase, .idle)
        XCTAssertTrue(harness.runner.skipped.isEmpty)
    }

    // MARK: - Cancel / finish

    @MainActor
    func testStopMidStepFinishesWithoutEmittingTheStepInProgress() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(4)
        harness.runner.finish()
        XCTAssertEqual(harness.runner.phase, .finished)
        XCTAssertTrue(harness.strap.bouts.isEmpty)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    @MainActor
    func testCancelRestoresAndASecondCancelIsANoOp() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.runner.cancel()
        XCTAssertEqual(harness.runner.phase, .cancelled)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
        harness.runner.cancel()
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
    }

    @MainActor
    func testBeginWhileRunningIsANoOp() throws {
        let harness = try makeHarness()
        harness.runner.begin(previousMode: .partTime)
        harness.runner.begin(previousMode: .continuous)
        XCTAssertEqual(harness.runner.phase, .ready(activity: 0))
        XCTAssertEqual(harness.strap.appliedModes, [.continuous])
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults), .partTime)
    }

    @MainActor
    func testBeginWithAnEmptyProtocolEndsCleanly() throws {
        let harness = try makeHarness(ActivityCalibrationProtocolModel(version: "empty", activities: []))
        harness.runner.begin(previousMode: .partTime)
        XCTAssertEqual(harness.runner.phase, .finished)
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    @MainActor
    func testOnBoutHandlerThatCancelsIsNotOverriddenByTheNextStep() throws {
        let harness = try makeHarness()
        harness.runner.onBout = { [weak harness] bout in
            harness?.strap.bouts.append(bout)
            harness?.runner.cancel()
        }
        harness.startFirstActivity()
        harness.advance(10)
        XCTAssertEqual(harness.runner.phase, .cancelled)
        XCTAssertEqual(harness.strap.bouts.count, 1)
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    // MARK: - Gate blocking

    @MainActor
    func testGateBlockedAtBeginRestoresAndClears() throws {
        let harness = try makeHarness()
        harness.strap.gateStatus = .blocked(.batteryLow(pct: 12))
        harness.runner.begin(previousMode: .partTime)
        XCTAssertEqual(harness.runner.phase, .gate(.batteryLow(pct: 12)))
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
        XCTAssertTrue(harness.strap.cues.isEmpty)
    }

    @MainActor
    func testGateBlockedMidStepStopsTheSessionAndKeepsEarlierBouts() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(10)
        harness.strap.gateStatus = .blocked(.rawSessionInFlight)
        harness.runner.refreshGate()
        XCTAssertEqual(harness.runner.phase, .gate(.rawSessionInFlight))
        XCTAssertEqual(harness.strap.bouts.map(\.taskId), ["a.hold-1"])
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }

    @MainActor
    func testGateIsAlsoCheckedWhileWaitingToStartAnActivity() throws {
        let harness = try makeHarness()
        harness.runner.begin(previousMode: .off)
        harness.strap.gateStatus = .blocked(.notOnWrist)
        harness.runner.refreshGate()
        XCTAssertEqual(harness.runner.phase, .gate(.notOnWrist))
        XCTAssertEqual(harness.strap.appliedModes, [.continuous, .off])
    }

    // MARK: - Relaunch recovery

    @MainActor
    func testMarkerSurvivesASimulatedRelaunch() throws {
        let harness = try makeHarness()
        harness.startFirstActivity()
        harness.advance(1)
        XCTAssertEqual(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults), .partTime)
        var restored: [ActivityImuCaptureMode] = []
        XCTAssertTrue(ActivityCalibrationRestoreMarker.restoreIfPending(applyMode: { restored.append($0) },
                                                                        defaults: harness.defaults))
        XCTAssertEqual(restored, [.partTime])
        XCTAssertNil(ActivityCalibrationRestoreMarker.pendingRestore(defaults: harness.defaults))
    }
}
