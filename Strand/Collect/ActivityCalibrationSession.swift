import Combine
import Foundation
import StrandAnalytics

// ActivityCalibrationSession.swift — guided activity ground-truth capture, phone side.
//
// This is the deterministic session state machine behind "Activity calibration" in Test Centre.
// It does NOT talk to BLE: every side effect (gate verdicts, IMU capture-mode application,
// strap haptics, the wall clock) is an injected closure, so the whole session protocol runs
// and is verified in a unit test with a fake clock and no strap.
//
// Why a durable marker: the single `activityImuCaptureMode` UserDefaults string is the only
// capture-mode store, and `continuous` is what a guided session forces while it runs. A crash
// mid-session would otherwise leave continuous capture armed forever. The marker records the
// previous mode BEFORE the mode is changed, and `pendingRestore()`/`restoreIfPending` undo it
// at next launch. Same crash-safe ordering idea as RawDataSessionStore's capture intent
// (`raw-data-session-capture-intent-v1`), except this marker is restored, not re-armed.

// MARK: - Durable restore marker

/// The "a guided activity session is mid-flight" marker. Written before any mode change, read at
/// launch to put the previous IMU capture mode back, cleared by the runner on every end path
/// (finish, cancel, gate block) so nothing is ever left forced.
public struct ActivityCalibrationRestoreMarker {
    public static let key = "activity-calibration-inflight-v1"

    /// The marker payload: the previous mode (raw string, matching `ActivityImuCaptureMode`) and
    /// when the session started, in unix milliseconds. `started_at` is informational only today —
    /// it lets a future session tell "killed 5 minutes ago" from "killed last week".
    private struct Payload: Codable, Equatable {
        var previousMode: String
        var startedAtMs: Int64
        enum CodingKeys: String, CodingKey {
            case previousMode = "previous_mode"
            case startedAtMs = "started_at"
        }
    }

    /// Persist the marker. Crash-safe ordering: the caller (the runner's `begin`) writes this
    /// BEFORE it applies `.continuous`, so a crash between the two still restores the old mode
    /// at next launch instead of leaving continuous capture armed.
    static func begin(previousMode: ActivityImuCaptureMode, now: Date, defaults: UserDefaults = .standard) {
        let payload = Payload(previousMode: previousMode.rawValue,
                              startedAtMs: Int64(now.timeIntervalSince1970 * 1_000))
        defaults.set(try? JSONEncoder().encode(payload), forKey: Self.key)
    }

    /// The mode a killed session must put back, or nil when no guided session is mid-flight.
    /// An undecodable value (garbage in the key) reads as nil, the safe direction: the caller
    /// would rather restore nothing than restore a mode it cannot name.
    static func pendingRestore(defaults: UserDefaults = .standard) -> ActivityImuCaptureMode? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return ActivityImuCaptureMode(rawValue: payload.previousMode)
    }

    /// Drop the marker. Called by the runner's teardown and by `restoreIfPending`.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.key)
    }

    /// One-shot launch restore: if a marker exists, apply the previous mode and clear the marker.
    /// Returns whether it restored anything, so a launch path can log the recovery. Applying and
    /// clearing happen in this one call so a crash between the two cannot re-apply twice.
    @discardableResult
    static func restoreIfPending(applyMode: (ActivityImuCaptureMode) -> Void,
                                 defaults: UserDefaults = .standard) -> Bool {
        guard let previous = pendingRestore(defaults: defaults) else { return false }
        applyMode(previous)
        clear(defaults: defaults)
        return true
    }
}

// MARK: - Guided session state machine

/// The guided capture session runner. A pure state machine: the owning view calls `tick()` from
/// its own timer (any cadence — transitions happen when `now()` passes a deadline, so coarse
/// ticks just land later, never twice), calls `refreshGate()` while a bout is active, and reads
/// `phase` to render. `begin`/`cancel`/`finish` are the only entry points that change flow.
///
/// Timing vocabulary (all unix seconds, from the injected `now` closure):
///   instructionTs      — when this repetition's instructions+countdown first appeared
///   countdownStartTs   — the 3 s countdown start
///   cueStartTs         — start haptic (the strap begins the labeled movement)
///   cueStopTs          — stop haptic (cueStartTs + task.durationSeconds)
///   intervalStartTs/EndTs — canonical guarded label interval [cueStart+guard, cueStop-guard);
///                        the seconds actually fed to evaluation, kept inside the cue boundaries
///                        so reaction-time edges around the haptics never contaminate the label.
///
/// Transition tasks add a third moment: `preStateSeconds` of quiet hold after the start cue, then
/// a "do it now" cue (auto-fired by the runner, or earlier via `markTransitionNow()` when the
/// user taps) that records `transitionTs`, then `postStateSeconds` of hold to the stop cue. The
/// transition itself is therefore always inside the guarded interval when
/// `preStateSeconds >= guardSeconds`, which the default protocol arranges.
@MainActor
public final class ActivityCalibrationSessionRunner: ObservableObject {
    /// Why a session could not run or had to stop. Produced by the injected `gate` closure —
    /// the runner never inspects BLE state itself, so this file stays free of BLE imports.
    public enum BlockedReason: Equatable, Sendable {
        case whoopNotConnected
        case notOnWrist
        case batteryLow(pct: Int)   // pct <= ActivityImuCapture.defaultPauseBatteryPct and not charging
        case rawUnavailable
        case rawSessionInFlight     // a Raw Data session owns the IMU stream; capture would fight it
    }

    /// The gate verdict. The UI supplies a closure that combines connection, on-wrist, battery
    /// and raw-capture availability into one value.
    public enum GateStatus: Equatable, Sendable {
        case ready
        case blocked(BlockedReason)
    }

    /// What the screen should show. `.gate` is a terminal blocked state (marker already cleared,
    /// previous mode already restored); `begin` may be called again from it.
    public enum Phase: Equatable, Sendable {
        case idle
        case gate(BlockedReason)
        case countdown(taskIndex: Int, endsAt: Date)
        case active(taskIndex: Int, rep: Int, cueStartTs: Int)
        case rest(taskIndex: Int, rep: Int, endsAt: Date)
        case finished
        case cancelled
    }

    @Published public private(set) var phase: Phase = .idle

    /// The local BLE device id the session is labeling, carried for the UI's label building
    /// (it is not part of `ActivityCalibrationBout`).
    public let deviceId: String?

    /// Called once per finished repetition, AFTER the stop cue, so the bout's timestamps are final.
    /// The UI turns each bout into an `ActivityGroundTruthLabel` and persists it.
    public var onBout: ((ActivityCalibrationBout) -> Void)?

    /// Seconds of the pre-task countdown.
    public static let countdownSeconds = 3

    private let model: ActivityCalibrationProtocolModel
    private let gate: () -> GateStatus
    private let applyMode: (ActivityImuCaptureMode) -> Void
    private let haptic: () -> Void
    private let now: () -> Date
    private let defaults: UserDefaults

    private var previousMode: ActivityImuCaptureMode?
    private var currentRep = 0
    private var instructionTs: Int?
    private var countdownStartTs: Int?
    private var cueStartTs = 0
    private var cueStopTs = 0
    private var intervalStartTs = 0
    private var intervalEndTs = 0
    private var transitionTs: Int?

    init(protocol model: ActivityCalibrationProtocolModel, deviceId: String?,
         gate: @escaping () -> GateStatus,
         applyMode: @escaping (ActivityImuCaptureMode) -> Void,
         haptic: @escaping () -> Void,
         now: @escaping () -> Date,
         defaults: UserDefaults = .standard) {
        self.model = model
        self.deviceId = deviceId
        self.gate = gate
        self.applyMode = applyMode
        self.haptic = haptic
        self.now = now
        self.defaults = defaults
    }

    // MARK: - Flow control

    /// Start a guided session over the protocol's tasks.
    ///
    /// Ordering is deliberate and crash-safe: the durable marker (with `previousMode`) lands
    /// BEFORE `.continuous` is applied, then the gate is checked. A blocked gate restores the
    /// previous mode immediately and clears the marker, so nothing is ever left forced.
    /// Calling `begin` while a session is already running is a no-op; after `.finished`,
    /// `.cancelled` or `.gate` it starts a fresh session.
    func begin(previousMode: ActivityImuCaptureMode) {
        guard canBegin else { return }
        self.previousMode = previousMode
        currentRep = 0
        transitionTs = nil
        ActivityCalibrationRestoreMarker.begin(previousMode: previousMode, now: now(), defaults: defaults)
        applyMode(.continuous)
        switch gate() {
        case .ready:
            // An empty protocol has nothing to capture: restore and end cleanly.
            guard !model.tasks.isEmpty else {
                teardown()
                phase = .finished
                return
            }
            beginCountdown(taskIndex: 0)
        case .blocked(let reason):
            block(reason)
        }
    }

    /// Stop the session as a normal end (last bout done, or the user tapped Finish). Publishes
    /// `.finished` after restoring the previous mode and clearing the marker. A no-op when the
    /// session is not running; a bout that is mid-capture is not emitted (only completed bouts,
    /// whose stop cue has fired, are).
    public func finish() {
        guard isRunning else { return }
        teardown()
        phase = .finished
    }

    /// Stop the session as an abort (user tapped Cancel, or a lifecycle interruption). Publishes
    /// `.cancelled` after restoring the previous mode and clearing the marker. Idempotent: a
    /// second `cancel` after `.cancelled`/`.finished` is a no-op.
    public func cancel() {
        guard isRunning else { return }
        teardown()
        phase = .cancelled
    }

    /// Re-check the gate mid-session (the UI calls this periodically while a bout is active and
    /// on scene-phase changes). A newly blocked gate stops the session exactly like a gate
    /// failure at `begin`: `.gate` published, previous mode restored, marker cleared.
    public func refreshGate() {
        guard isRunning else { return }
        switch gate() {
        case .ready:
            break
        case .blocked(let reason):
            block(reason)
        }
    }

    /// Advance the state machine. Call from the owning view's timer; safe to call at any cadence
    /// and any time. Deadlines are compared against the injected `now`, so no work is skipped
    /// when a tick is late — the next state just starts at the actual wall time.
    public func tick() {
        guard isRunning else { return }
        switch phase {
        case .countdown(let taskIndex, let endsAt):
            if now() >= endsAt { startActive(taskIndex: taskIndex) }
        case .active(let taskIndex, let rep, _):
            maybeFireTransitionCue(taskIndex: taskIndex)
            if nowSeconds >= cueStopTs { endActive(taskIndex: taskIndex, rep: rep) }
        case .rest(let taskIndex, let rep, let endsAt):
            if now() >= endsAt { advanceAfterRest(taskIndex: taskIndex, rep: rep) }
        case .idle, .gate, .finished, .cancelled:
            break
        }
    }

    /// The "do it now" tap for a transition task: the user performs the transition early, before
    /// the auto-fired cue. Records `transitionTs` at the tap and buzzes. No-op for non-transition
    /// tasks and when the transition moment is already recorded.
    public func markTransitionNow() {
        guard case .active(let taskIndex, _, _) = phase else { return }
        guard model.tasks[taskIndex].transitionKind != nil else { return }
        guard transitionTs == nil else { return }
        transitionTs = nowSeconds
        haptic()
    }

    // MARK: - Private transitions

    private var canBegin: Bool {
        switch phase {
        case .idle, .gate, .finished, .cancelled:
            return true
        case .countdown, .active, .rest:
            return false   // already in flight
        }
    }

    private var isRunning: Bool {
        switch phase {
        case .countdown, .active, .rest:
            return true
        case .idle, .gate, .finished, .cancelled:
            return false
        }
    }

    private var nowSeconds: Int { Int(now().timeIntervalSince1970) }

    private func beginCountdown(taskIndex: Int) {
        // Instructions are on screen for the whole countdown; both timestamps land when the
        // countdown begins. They are distinct fields on the bout so a future UI that shows
        // instructions earlier (or per-repetition) can record the real moments separately.
        instructionTs = nowSeconds
        countdownStartTs = nowSeconds
        let endsAt = now().addingTimeInterval(TimeInterval(Self.countdownSeconds))
        phase = .countdown(taskIndex: taskIndex, endsAt: endsAt)
    }

    private func startActive(taskIndex: Int) {
        let task = model.tasks[taskIndex]
        cueStartTs = nowSeconds
        cueStopTs = cueStartTs + task.durationSeconds
        intervalStartTs = cueStartTs + task.guardSeconds
        intervalEndTs = cueStopTs - task.guardSeconds
        transitionTs = nil
        // A transition task's only movement cue is "do it now": a start buzz a few seconds earlier
        // reads as that cue, and people move on the wrong one.
        if !Self.hasHeldPreState(task) { haptic() }   // start cue
        phase = .active(taskIndex: taskIndex, rep: currentRep, cueStartTs: cueStartTs)
    }

    /// Auto-fire the transition cue once `preStateSeconds` of quiet hold have passed since the
    /// start cue. Runs only for transition tasks and only once per repetition.
    static func hasHeldPreState(_ task: ActivityCalibrationTask) -> Bool {
        task.transitionKind != nil && (task.preStateSeconds ?? 0) > 0
    }

    private func maybeFireTransitionCue(taskIndex: Int) {
        guard transitionTs == nil else { return }
        let task = model.tasks[taskIndex]
        guard Self.hasHeldPreState(task), let pre = task.preStateSeconds else { return }
        guard nowSeconds >= cueStartTs + pre else { return }
        transitionTs = nowSeconds
        haptic()   // "do it now" cue
    }

    private func endActive(taskIndex: Int, rep: Int) {
        haptic()   // stop cue
        let task = model.tasks[taskIndex]
        let bout = ActivityCalibrationBout(
            taskId: task.id,
            repetition: rep + 1,
            instructionTs: instructionTs,
            countdownStartTs: countdownStartTs,
            cueStartTs: cueStartTs,
            cueStopTs: cueStopTs,
            intervalStartTs: intervalStartTs,
            intervalEndTs: intervalEndTs,
            posture: task.posture,
            locomotion: task.locomotion,
            armBehavior: task.armBehavior,
            semanticTag: task.semanticTag,
            transitionKind: task.transitionKind,
            transitionTs: transitionTs,
            protocolVersion: model.version)
        onBout?(bout)
        // The onBout handler is the UI's label path; if it synchronously cancelled or finished
        // the session (its own lifecycle), do not override that decision with a rest phase.
        guard isRunning else { return }
        let isLast = taskIndex == model.tasks.count - 1 && rep == task.repetitions - 1
        if isLast {
            // No trailing rest after the final bout: the session is done the moment the stop
            // cue fires, so a user who walks away is not kept in a rest phase.
            finish()
        } else {
            let endsAt = now().addingTimeInterval(TimeInterval(task.restSeconds))
            phase = .rest(taskIndex: taskIndex, rep: rep, endsAt: endsAt)
        }
    }

    /// Rest is over: re-check the gate (a disconnect or a Raw Data session that started during
    /// the rest must stop us before we label blind seconds), then start the next repetition or
    /// the next task's countdown.
    private func advanceAfterRest(taskIndex: Int, rep: Int) {
        switch gate() {
        case .blocked(let reason):
            block(reason)
            return
        case .ready:
            break
        }
        let task = model.tasks[taskIndex]
        if rep < task.repetitions - 1 {
            // Same task, next repetition: keep counting up so the bout's `repetition` advances.
            currentRep = rep + 1
            beginCountdown(taskIndex: taskIndex)
        } else {
            // Task done: reset the repetition counter for the next task's first bout.
            currentRep = 0
            beginCountdown(taskIndex: taskIndex + 1)
        }
    }

    /// Terminal blocked path, shared by begin-time and mid-session gate failures: clear the
    /// marker and restore the previous mode BEFORE publishing `.gate`, so an observer of the
    /// published phase sees a fully restored system.
    private func block(_ reason: BlockedReason) {
        teardown()
        phase = .gate(reason)
    }

    private func teardown() {
        ActivityCalibrationRestoreMarker.clear(defaults: defaults)
        if let previousMode {
            applyMode(previousMode)
        }
        self.previousMode = nil
    }
}

// MARK: - Per-repetition output

/// One completed repetition of a guided calibration task, as recorded by the runner and handed to
/// the UI's label builder. All timestamps are unix seconds. The canonical evaluation interval is
/// `[intervalStartTs, intervalEndTs)`; the cue timestamps are preserved beside it so the raw
/// seconds and the reaction-time margins stay auditable.
public struct ActivityCalibrationBout: Codable, Equatable, Sendable {
    public var taskId: String
    /// 1-based repetition number within the task.
    public var repetition: Int
    public var instructionTs: Int?
    public var countdownStartTs: Int?
    public var cueStartTs: Int
    public var cueStopTs: Int
    /// cueStartTs + guardSeconds ..< cueStopTs - guardSeconds
    public var intervalStartTs: Int
    public var intervalEndTs: Int
    public var posture: String?
    public var locomotion: String?
    public var armBehavior: String?
    public var semanticTag: String?
    public var transitionKind: String?
    public var transitionTs: Int?
    public var protocolVersion: String

    public init(taskId: String, repetition: Int, instructionTs: Int?, countdownStartTs: Int?,
                cueStartTs: Int, cueStopTs: Int, intervalStartTs: Int, intervalEndTs: Int,
                posture: String?, locomotion: String?, armBehavior: String?,
                semanticTag: String?, transitionKind: String?, transitionTs: Int?,
                protocolVersion: String) {
        self.taskId = taskId
        self.repetition = repetition
        self.instructionTs = instructionTs
        self.countdownStartTs = countdownStartTs
        self.cueStartTs = cueStartTs
        self.cueStopTs = cueStopTs
        self.intervalStartTs = intervalStartTs
        self.intervalEndTs = intervalEndTs
        self.posture = posture
        self.locomotion = locomotion
        self.armBehavior = armBehavior
        self.semanticTag = semanticTag
        self.transitionKind = transitionKind
        self.transitionTs = transitionTs
        self.protocolVersion = protocolVersion
    }
}
