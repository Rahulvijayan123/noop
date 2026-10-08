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
/// its own timer (transitions happen when `now()` passes a deadline, so a late tick lands late,
/// never twice), calls `refreshGate()` while running, and renders `phase`.
///
/// Flow: `begin` -> `.ready(0)` -> `start` -> `.countdown` -> `.step` ... -> `.ready(1)` -> ... ->
/// `.finished`. Each activity waits at `.ready` for the wearer to be in position; inside it the steps
/// run back to back with no taps. `skip` drops the current activity (and only its unfinished step)
/// from `.ready`, `.countdown` or `.step` and moves on.
///
/// Cues are exactly two, so a buzz always means one thing:
///   `.move` — fired at a move's `cueSeconds`: change posture now. Holds never buzz.
///   `.done` — fired when an activity's last step ends: relax, the activity is over.
/// The published step carries the same `Date` deadlines the runner acts on, and `moved` flips in
/// the same tick the `.move` cue fires, so the screen can never say "move" before the buzz.
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

    public enum Cue: Equatable, Sendable {
        case move
        case done
    }

    /// The step being recorded. `cueAt` is nil for holds.
    public struct Step: Equatable, Sendable {
        public var activity: Int
        public var task: Int
        public var startedAt: Date
        public var endsAt: Date
        public var cueAt: Date?
        /// The `.move` cue has fired (and `transitionTs` is recorded).
        public var moved: Bool
    }

    /// What the screen should show. `.gate` is a terminal blocked state (marker already cleared,
    /// previous mode already restored); `begin` may be called again from it.
    public enum Phase: Equatable, Sendable {
        case idle
        case gate(BlockedReason)
        case ready(activity: Int)
        case countdown(activity: Int, endsAt: Date)
        case step(Step)
        case finished
        case cancelled
    }

    @Published public private(set) var phase: Phase = .idle
    /// Activities skipped in this session, by index.
    @Published public private(set) var skipped: Set<Int> = []

    /// The local BLE device id the session is labeling, carried for the UI's label building
    /// (it is not part of `ActivityCalibrationBout`).
    public let deviceId: String?

    /// Called once per completed step, after its end deadline, so the bout's timestamps are final.
    /// The UI turns each bout into an `ActivityGroundTruthLabel` and persists it.
    public var onBout: ((ActivityCalibrationBout) -> Void)?

    public let model: ActivityCalibrationProtocolModel
    private let gate: () -> GateStatus
    private let applyMode: (ActivityImuCaptureMode) -> Void
    private let haptic: (Cue) -> Void
    private let now: () -> Date
    private let defaults: UserDefaults

    private var previousMode: ActivityImuCaptureMode?
    private var transitionAt: Date?

    init(protocol model: ActivityCalibrationProtocolModel, deviceId: String?,
         gate: @escaping () -> GateStatus,
         applyMode: @escaping (ActivityImuCaptureMode) -> Void,
         haptic: @escaping (Cue) -> Void,
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

    /// Start a session and wait at the first activity.
    ///
    /// Ordering is deliberate and crash-safe: the durable marker (with `previousMode`) lands
    /// BEFORE `.continuous` is applied, then the gate is checked. A blocked gate restores the
    /// previous mode immediately and clears the marker, so nothing is ever left forced.
    /// Calling `begin` while a session is already running is a no-op; after `.finished`,
    /// `.cancelled` or `.gate` it starts a fresh session.
    func begin(previousMode: ActivityImuCaptureMode) {
        guard !isRunning else { return }
        self.previousMode = previousMode
        skipped = []
        transitionAt = nil
        ActivityCalibrationRestoreMarker.begin(previousMode: previousMode, now: now(), defaults: defaults)
        applyMode(.continuous)
        switch gate() {
        case .ready:
            enterActivity(0)
        case .blocked(let reason):
            block(reason)
        }
    }

    /// The wearer is in position: run the start countdown, then the activity's first step.
    public func start() {
        guard case .ready(let activity) = phase else { return }
        phase = .countdown(activity: activity,
                           endsAt: now().addingTimeInterval(TimeInterval(ActivityCalibrationProtocols.startCountdownSeconds)))
    }

    /// Leave the current activity out and move to the next one. Bouts this activity already
    /// emitted stay saved; the step in progress is dropped. No cue fires.
    public func skip() {
        let activity: Int
        switch phase {
        case .ready(let a), .countdown(let a, _): activity = a
        case .step(let s): activity = s.activity
        default: return
        }
        skipped.insert(activity)
        transitionAt = nil
        enterActivity(activity + 1)
    }

    /// Stop the session as a normal end (the user tapped Stop, or the last activity ended).
    /// Publishes `.finished` after restoring the previous mode and clearing the marker. A step
    /// that is mid-capture is not emitted.
    public func finish() {
        guard isRunning else { return }
        teardown()
        phase = .finished
    }

    /// Stop the session as an abort (a lifecycle interruption such as backgrounding). Publishes
    /// `.cancelled` after restoring the previous mode and clearing the marker. Idempotent.
    public func cancel() {
        guard isRunning else { return }
        teardown()
        phase = .cancelled
    }

    /// Re-check the gate mid-session (the UI calls this periodically and on scene-phase
    /// changes). A newly blocked gate stops the session exactly like a gate failure at `begin`.
    public func refreshGate() {
        guard isRunning else { return }
        if case .blocked(let reason) = gate() { block(reason) }
    }

    /// Advance the state machine. Call from the owning view's timer at any cadence; deadlines are
    /// compared against the injected `now`, and at most one deadline is acted on per tick.
    public func tick() {
        let t = now()
        switch phase {
        case .countdown(let activity, let endsAt):
            if t >= endsAt { startStep(activity: activity, task: 0, at: Self.chainStart(deadline: endsAt, now: t)) }
        case .step(var step):
            if !step.moved, let cueAt = step.cueAt, t >= cueAt {
                transitionAt = t
                step.moved = true
                phase = .step(step)
                haptic(.move)
            } else if t >= step.endsAt {
                endStep(step, now: t)
            }
        case .idle, .gate, .ready, .finished, .cancelled:
            break
        }
    }

    public var isRunning: Bool {
        switch phase {
        case .ready, .countdown, .step: return true
        case .idle, .gate, .finished, .cancelled: return false
        }
    }

    // MARK: - Private transitions

    private func enterActivity(_ index: Int) {
        if model.activities.indices.contains(index) {
            phase = .ready(activity: index)
        } else {
            finish()
        }
    }

    /// Steps chain on the previous deadline, not on the tick that noticed it, so a late tick never
    /// stretches the protocol or shifts the next step's cue. After a real stall (over a second) the
    /// next step starts now instead, so its cue never fires early to catch up.
    static func chainStart(deadline: Date, now: Date) -> Date {
        now.timeIntervalSince(deadline) > 1 ? now : deadline
    }

    private func startStep(activity: Int, task: Int, at start: Date) {
        let spec = model.activities[activity].tasks[task]
        transitionAt = nil
        phase = .step(Step(activity: activity, task: task, startedAt: start,
                           endsAt: start.addingTimeInterval(TimeInterval(spec.durationSeconds)),
                           cueAt: spec.cueSeconds.map { start.addingTimeInterval(TimeInterval($0)) },
                           moved: false))
    }

    private func endStep(_ step: Step, now t: Date) {
        let spec = model.activities[step.activity].tasks[step.task]
        onBout?(bout(for: step, spec: spec))
        // The onBout handler is the UI's label path; if it ended the session, keep that decision.
        guard case .step = phase else { return }
        if step.task + 1 < model.activities[step.activity].tasks.count {
            startStep(activity: step.activity, task: step.task + 1, at: Self.chainStart(deadline: step.endsAt, now: t))
        } else {
            haptic(.done)
            enterActivity(step.activity + 1)
        }
    }

    private func bout(for step: Step, spec: ActivityCalibrationTask) -> ActivityCalibrationBout {
        let start = step.startedAt.timeIntervalSince1970
        let end = step.endsAt.timeIntervalSince1970
        let guardS = TimeInterval(spec.guardSeconds)
        let intervalStart = Int((start + guardS).rounded(.up))
        let intervalEnd = Int((end - guardS).rounded(.down))
        // The server rejects a transition_ts outside the label interval (`invalid_transition_ts`).
        let transitionTs = transitionAt.map {
            min(max(Int($0.timeIntervalSince1970.rounded()), intervalStart), intervalEnd)
        }
        return ActivityCalibrationBout(
            taskId: spec.id,
            stepStartTs: Int(start.rounded(.down)),
            stepEndTs: Int(end.rounded(.up)),
            cueTs: step.cueAt.map { Int($0.timeIntervalSince1970.rounded()) },
            intervalStartTs: intervalStart,
            intervalEndTs: intervalEnd,
            posture: spec.posture,
            transitionKind: spec.transitionKind,
            transitionTs: transitionTs,
            protocolVersion: model.version)
    }

    /// Terminal blocked path, shared by begin-time and mid-session gate failures: clear the
    /// marker and restore the previous mode BEFORE publishing `.gate`, so an observer of the
    /// published phase sees a fully restored system.
    private func block(_ reason: BlockedReason) {
        teardown()
        phase = .gate(reason)
    }

    private func teardown() {
        // Restore before clearing the marker: a crash in between leaves the marker, so the next
        // launch restores again instead of leaving `.continuous` armed with no marker.
        if let previousMode {
            applyMode(previousMode)
        }
        ActivityCalibrationRestoreMarker.clear(defaults: defaults)
        self.previousMode = nil
        transitionAt = nil
    }
}

// MARK: - Per-step output

/// One completed step of a guided session, as recorded by the runner and handed to the UI's label
/// builder. All timestamps are unix seconds. The canonical evaluation interval is
/// `[intervalStartTs, intervalEndTs)`; the step edges and the move cue are kept beside it so the
/// reaction-time margins stay auditable.
public struct ActivityCalibrationBout: Codable, Equatable, Sendable {
    public var taskId: String
    public var stepStartTs: Int
    public var stepEndTs: Int
    /// When a move's "move now" buzz was due; nil for holds.
    public var cueTs: Int?
    /// stepStart + guardSeconds ..< stepEnd - guardSeconds
    public var intervalStartTs: Int
    public var intervalEndTs: Int
    public var posture: String?
    public var transitionKind: String?
    /// When the "move now" buzz actually fired, inside the interval.
    public var transitionTs: Int?
    public var protocolVersion: String

    public init(taskId: String, stepStartTs: Int, stepEndTs: Int, cueTs: Int?,
                intervalStartTs: Int, intervalEndTs: Int, posture: String?,
                transitionKind: String?, transitionTs: Int?, protocolVersion: String) {
        self.taskId = taskId
        self.stepStartTs = stepStartTs
        self.stepEndTs = stepEndTs
        self.cueTs = cueTs
        self.intervalStartTs = intervalStartTs
        self.intervalEndTs = intervalEndTs
        self.posture = posture
        self.transitionKind = transitionKind
        self.transitionTs = transitionTs
        self.protocolVersion = protocolVersion
    }
}
