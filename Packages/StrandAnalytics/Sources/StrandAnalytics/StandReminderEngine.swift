import Foundation
import WhoopProtocol

// StandReminderEngine.swift — "you have not stood or moved enough" over a rolling window.
//
// THE RULE. Look at the previous `windowMinutes` (50 by default) ending at the newest second the strap has
// told us about. Add up every second of meaningful standing or movement inside it. If that comes to at least
// `requiredMovementSeconds` (one minute) the wearer is fine, however it was spread; otherwise - and only if
// they were really sedentary for the rest of the window - they are due a reminder.
//
//   • 2 minutes of walking in the last 50          → no reminder
//   • 70 s of standing / moving                    → no reminder
//   • 20 s of movement                             → still eligible
//   • 50 minutes seated                            → reminder
//   • six 12-second walks to the kettle            → no reminder (72 s accumulated, never one block)
//
// WHAT COUNTS. Not elapsed time and not raw wrist motion: the canonical activity class of each stretch
// (`ActivityClassifier`, from the same decoder that labels the timeline) plus the strap's step counter.
//   movement  standing · light activity · walking · brisk walking · running · cycling · higher-intensity activity,
//             and any stretch where steps were counted even if the heads read "seated" (carrying a laptop
//             across the room leaves the wrist almost still but the step counter keeps going).
//   sedentary sitting · sitting at a desk · still (sitting or standing, unresolved) · fidgeting.
//   neither   lying down (a couch nap must not be buzzed awake), unknown (no claim), and asleep / off-wrist,
//             which also come out of the window's coverage, so "just got up" or "just put it on" is not
//             "sedentary for 50 minutes".
// A movement bout has to last `minBoutSeconds` (10 s) to count, so a hand gesture the classifier briefly
// reads as "moving" cannot accumulate into a minute of credit by itself; moving seconds no further apart
// than `bridgeGapSeconds` (5 s) are one bout.
//
// WHAT IT CANNOT SEE. A wrist cannot tell sitting from standing still (see `ActivityClass.capabilities`):
// someone who stands motionless for a minute is credited only if the heads lean clearly upright. The engine
// errs the other way on everything it is unsure of - unknown, lying down, thin coverage - because a
// reminder that arrives while the wearer has been up and about is the failure people stop trusting.
//
// FRESHNESS. History reaches the phone in offloads (~every 15 minutes), so the window ends at the newest
// second of data, not at the clock, and data older than `staleAfterSeconds` is not acted on at all. A
// reminder also waits `holdoffSeconds` after movement ends (they are already getting up), and is spaced
// `reNudgeMinutes` apart while the wearer stays put.
//
// PURITY. No I/O, no clock reads: `nowSec` and `tzOffsetSec` come in, the next `State` comes out. The
// legacy gravity-only `SedentaryDetector` is untouched (its tests still run) but the app no longer routes
// reminders through it: a reminder with no activity-context data for the window is not sent at all.

public enum StandReminderEngine {

    // MARK: Configuration

    public struct Config: Equatable, Sendable {
        // User knobs and global gates (the same ones the legacy reminder reads).
        public var enabled: Bool
        public var notificationsMasterOn: Bool
        /// Length of the rolling window, minutes.
        public var windowMinutes: Int
        /// While the wearer stays put, remind again no sooner than this.
        public var reNudgeMinutes: Int
        public var buzzLoops: Int
        public var activeHoursEnabled: Bool
        public var activeStartMinutes: Int
        public var activeEndMinutes: Int
        public var quietHoursEnabled: Bool
        public var quietStartMinutes: Int
        public var quietEndMinutes: Int
        public var onlyWhenWorn: Bool

        // The rule itself.
        /// Accumulated standing / movement that satisfies the window.
        public var requiredMovementSeconds: Int
        /// A movement bout shorter than this does not count.
        public var minBoutSeconds: Int
        /// Moving seconds no further apart than this belong to one bout.
        public var bridgeGapSeconds: Int
        /// A movement class needs at least this belief to earn credit.
        public var minClassConfidence: Double
        /// Share of the window that must be observed awake and on the wrist.
        public var minCoverage: Double
        /// Share of the window that must be positively sedentary.
        public var minSedentaryShare: Double
        /// Do not remind within this long of a movement bout ending.
        public var holdoffSeconds: Int
        /// Data older than this (relative to now) is not acted on.
        public var staleAfterSeconds: Int
        /// Step ticks in a 5-second bin that make it a stepping bin.
        public var stepBurstTicks: Int

        public init(enabled: Bool = false, notificationsMasterOn: Bool = false,
                    windowMinutes: Int = StandReminderEngine.defaultWindowMinutes,
                    reNudgeMinutes: Int = SedentaryDetector.defaultReNudgeMinutes,
                    buzzLoops: Int = SedentaryDetector.defaultBuzzLoops,
                    activeHoursEnabled: Bool = true,
                    activeStartMinutes: Int = SedentaryDetector.defaultActiveStartMin,
                    activeEndMinutes: Int = SedentaryDetector.defaultActiveEndMin,
                    quietHoursEnabled: Bool = false,
                    quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                    quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                    onlyWhenWorn: Bool = true,
                    requiredMovementSeconds: Int = 60, minBoutSeconds: Int = 10, bridgeGapSeconds: Int = 5,
                    minClassConfidence: Double = 0.25, minCoverage: Double = 0.85, minSedentaryShare: Double = 0.8,
                    holdoffSeconds: Int = 30, staleAfterSeconds: Int = 20 * 60, stepBurstTicks: Int = 4) {
            self.enabled = enabled; self.notificationsMasterOn = notificationsMasterOn
            self.windowMinutes = windowMinutes; self.reNudgeMinutes = reNudgeMinutes; self.buzzLoops = buzzLoops
            self.activeHoursEnabled = activeHoursEnabled
            self.activeStartMinutes = activeStartMinutes; self.activeEndMinutes = activeEndMinutes
            self.quietHoursEnabled = quietHoursEnabled
            self.quietStartMinutes = quietStartMinutes; self.quietEndMinutes = quietEndMinutes
            self.onlyWhenWorn = onlyWhenWorn
            self.requiredMovementSeconds = requiredMovementSeconds; self.minBoutSeconds = minBoutSeconds
            self.bridgeGapSeconds = bridgeGapSeconds; self.minClassConfidence = minClassConfidence
            self.minCoverage = minCoverage; self.minSedentaryShare = minSedentaryShare
            self.holdoffSeconds = holdoffSeconds; self.staleAfterSeconds = staleAfterSeconds
            self.stepBurstTicks = stepBurstTicks
        }

        /// The user's stored reminder settings (they are shared with the legacy detector): its "minutes
        /// before the first nudge" is this engine's window.
        public init(_ legacy: SedentaryConfig) {
            self.init(enabled: legacy.enabled, notificationsMasterOn: legacy.notificationsMasterOn,
                      windowMinutes: legacy.thresholdMinutes, reNudgeMinutes: legacy.reNudgeMinutes,
                      buzzLoops: legacy.buzzLoops, activeHoursEnabled: legacy.activeHoursEnabled,
                      activeStartMinutes: legacy.activeStartMinutes, activeEndMinutes: legacy.activeEndMinutes,
                      quietHoursEnabled: legacy.quietHoursEnabled, quietStartMinutes: legacy.quietStartMinutes,
                      quietEndMinutes: legacy.quietEndMinutes, onlyWhenWorn: legacy.onlyWhenWorn)
        }

        public var windowSeconds: Int { max(1, windowMinutes) * 60 }
    }

    /// 50 minutes: long enough to be a real sedentary spell, short enough to beat the hourly habit.
    public static let defaultWindowMinutes = 50

    /// What the engine carries between evaluations (restart-safe, persisted by the caller).
    public struct State: Equatable, Sendable {
        /// The newest data second already judged: an evaluation with nothing newer is a no-op.
        public var lastEvaluatedThrough: Int
        /// Unix seconds of the last reminder (0 = never).
        public var lastRemindAt: Int
        public init(lastEvaluatedThrough: Int = 0, lastRemindAt: Int = 0) {
            self.lastEvaluatedThrough = lastEvaluatedThrough; self.lastRemindAt = lastRemindAt
        }
        public static let initial = State()
    }

    // MARK: Result

    /// Why the engine did or did not remind: the exact gate that decided.
    public enum Reason: String, Sendable {
        case remind
        case disabled, notificationsOff, quietHours, outsideActiveHours, notWorn
        case noData, staleData, replayed
        case insufficientCoverage, movedEnough, notSedentary, recentlyMoving, cooldown
    }

    /// The window the decision was made over.
    public struct Window: Equatable, Sendable {
        public let start: Int
        public let end: Int
        /// Accumulated credited standing / movement.
        public let movementSeconds: Int
        /// Seconds positively sedentary (seated, desk, still, fidgeting) and not credited.
        public let sedentarySeconds: Int
        /// Seconds observed awake and on the wrist.
        public let observedSeconds: Int
        /// End of the most recent credited movement bout, nil when there was none in the window.
        public let lastMovementEnd: Int?

        public init(start: Int, end: Int, movementSeconds: Int, sedentarySeconds: Int, observedSeconds: Int,
                    lastMovementEnd: Int?) {
            self.start = start; self.end = end; self.movementSeconds = movementSeconds
            self.sedentarySeconds = sedentarySeconds; self.observedSeconds = observedSeconds
            self.lastMovementEnd = lastMovementEnd
        }

        public var lengthSeconds: Int { end - start }
        public var coverage: Double { lengthSeconds > 0 ? Double(observedSeconds) / Double(lengthSeconds) : 0 }
        public var sedentaryShare: Double { lengthSeconds > 0 ? Double(sedentarySeconds) / Double(lengthSeconds) : 0 }
    }

    public struct Decision: Equatable, Sendable {
        public let shouldRemind: Bool
        public let reason: Reason
        /// Nil when the engine stopped before looking at the data.
        public let window: Window?
        public let buzzLoops: Int
        public let nextState: State

        public init(shouldRemind: Bool, reason: Reason, window: Window?, buzzLoops: Int, nextState: State) {
            self.shouldRemind = shouldRemind; self.reason = reason; self.window = window
            self.buzzLoops = buzzLoops; self.nextState = nextState
        }
    }

    // MARK: Inputs

    /// Per-second step ticks inside `[start, end)` from the strap's cumulative step counter, in time order.
    /// The same differencing the activity decoder uses (consecutive samples 1-2 s apart, wrap-safe, capped at
    /// the gait ceiling), so the reminder and the timeline agree on what counted as stepping. Pass ONE strap's
    /// counter: two straps' counters interleaved would fabricate deltas.
    public static func stepTicks(from counter: [StepSample], start: Int, end: Int) -> [(ts: Int, ticks: Int)] {
        ActivityContextTrackBuilder.stepTicksAndClasses(counter, lo: start, hi: end).ticks
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { (ts: $0.key, ticks: $0.value) }
    }

    // MARK: Credit

    /// The credit accumulated in `[start, end)`; the pure heart of the rule, exposed so a screen or the
    /// coach can show the same numbers the reminder acted on.
    public static func window(runs: [ActivityContextRun], stepTicks: [(ts: Int, ticks: Int)] = [],
                              start: Int, end: Int, config: Config = Config()) -> Window {
        let n = max(0, end - start)
        guard n > 0 else {
            return Window(start: start, end: end, movementSeconds: 0, sedentarySeconds: 0, observedSeconds: 0,
                          lastMovementEnd: nil)
        }
        // 0 no data · 1 observed, no claim · 2 sedentary · 3 movement class · 4 asleep / off-wrist
        var kind = [UInt8](repeating: 0, count: n)
        for run in runs where run.end > run.start && run.end > start && run.start < end {
            let k = ActivityClassifier.classify(run: run)
            let value: UInt8
            switch k.activityClass {
            case .offWrist, .sleeping: value = 4
            case .sitting, .sittingDesk, .stationary, .fidgeting: value = 2
            case .standing, .lightActivity, .walking, .briskWalking, .running, .cycling, .vigorousActivity:
                value = k.confidence >= config.minClassConfidence ? 3 : 1
            case .lyingDown, .unknown: value = 1
            }
            for t in max(run.start, start)..<min(run.end, end) { kind[t - start] = value }
        }

        var moving = kind.map { $0 == 3 }
        var bins: [Int: Int] = [:]
        for (ts, ticks) in stepTicks where ts >= start && ts < end && ticks > 0 { bins[(ts - start) / 5, default: 0] += ticks }
        for (bin, ticks) in bins where ticks >= config.stepBurstTicks {
            for i in (bin * 5)..<min(n, bin * 5 + 5) where kind[i] != 4 && kind[i] != 0 { moving[i] = true }
        }

        var credited = 0
        var lastEnd: Int?
        var i = 0
        while i < n {
            guard moving[i] else { i += 1; continue }
            var j = i, lastTrue = i
            while j < n, j - lastTrue <= config.bridgeGapSeconds {
                if moving[j] { lastTrue = j }
                j += 1
            }
            let length = lastTrue - i + 1
            if length >= config.minBoutSeconds {
                for t in i...lastTrue { moving[t] = true }
                credited += length
                lastEnd = start + lastTrue + 1
            } else {
                for t in i...lastTrue { moving[t] = false }
            }
            i = lastTrue + 1
        }

        var sedentary = 0, observed = 0
        for t in 0..<n {
            switch kind[t] {
            case 1, 3: observed += 1
            case 2: observed += 1; if !moving[t] { sedentary += 1 }
            default: break
            }
        }
        return Window(start: start, end: end, movementSeconds: credited, sedentarySeconds: sedentary,
                      observedSeconds: observed, lastMovementEnd: lastEnd)
    }

    // MARK: Decision

    public static func evaluate(runs: [ActivityContextRun], stepTicks: [(ts: Int, ticks: Int)] = [],
                                state: State, config: Config, worn: Bool,
                                nowSec: Int, tzOffsetSec: Int) -> Decision {
        func stop(_ reason: Reason, _ window: Window? = nil, next: State? = nil) -> Decision {
            Decision(shouldRemind: false, reason: reason, window: window, buzzLoops: config.buzzLoops,
                     nextState: next ?? state)
        }
        guard config.enabled else { return stop(.disabled) }
        guard config.notificationsMasterOn else { return stop(.notificationsOff) }
        guard let through = runs.map(\.end).max() else { return stop(.noData) }
        guard nowSec - through <= config.staleAfterSeconds else { return stop(.staleData) }

        let end = min(nowSec, through)
        guard end > state.lastEvaluatedThrough else { return stop(.replayed) }
        var next = state
        next.lastEvaluatedThrough = end

        let minute = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
        if config.quietHoursEnabled,
           SedentaryDetector.windowContains(minute, startMin: config.quietStartMinutes, endMin: config.quietEndMinutes) {
            return stop(.quietHours, next: next)
        }
        if config.activeHoursEnabled,
           !SedentaryDetector.windowContains(minute, startMin: config.activeStartMinutes, endMin: config.activeEndMinutes) {
            return stop(.outsideActiveHours, next: next)
        }
        if config.onlyWhenWorn && !worn { return stop(.notWorn, next: next) }

        let w = window(runs: runs, stepTicks: stepTicks, start: end - config.windowSeconds, end: end, config: config)
        if w.coverage < config.minCoverage { return stop(.insufficientCoverage, w, next: next) }
        if w.movementSeconds >= config.requiredMovementSeconds { return stop(.movedEnough, w, next: next) }
        if w.sedentaryShare < config.minSedentaryShare { return stop(.notSedentary, w, next: next) }
        if let last = w.lastMovementEnd, end - last < config.holdoffSeconds { return stop(.recentlyMoving, w, next: next) }
        if state.lastRemindAt > 0, nowSec - state.lastRemindAt < config.reNudgeMinutes * 60 {
            return stop(.cooldown, w, next: next)
        }

        next.lastRemindAt = nowSec
        return Decision(shouldRemind: true, reason: .remind, window: w, buzzLoops: config.buzzLoops, nextState: next)
    }
}
