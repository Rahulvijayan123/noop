import Foundation

// ActivityTransitionProximity.swift — how long ago a postural/locomotor transition happened, and what
// that means for trusting a physiology window measured nearby.
//
// Autonomic tone does not snap back to steady-state the instant the body stops moving: standing up,
// sitting down, lying down, getting up, or stopping a walk/run all leave a wake behind them in heart rate
// and HRV that outlasts the posture change itself. A window measured 5 s after someone sat back down
// still reflects standing, not sitting. The decoder already tracks a version of this for its own
// reasoning (`ActivityHistorySummary.sinceLocomotionS`); this file generalises the pattern into a shared,
// reusable phase so an HRV eligibility gate (`HRVWindow`) and anything else can use the same boundaries.

/// Where a moment sits relative to the most recent behavioural transition.
public enum ActivityPhysiologyPhase: String, Equatable, Sendable {
    /// Inside the settling window right after a transition: HR/HRV still carries the preceding activity.
    case transition
    /// Past the settling window but not yet far enough out to call steady: usable for its own sake, but
    /// not as a resting baseline observation.
    case recovery
    /// Far enough from any known transition that the reading describes the CURRENT behaviour, not the one
    /// before it.
    case steadyState = "steady_state"
    /// No transition-event data was available for the span at all (no decoder output), so "no event in
    /// the lookback" cannot be told apart from "events were never looked for". Never a resting baseline
    /// observation. Distinct from a decoded span that simply had no events, which reads `steadyState`.
    case unknown
}

public enum ActivityTransitionProximity {
    /// Default width of the `transition` window: the first 30 s after a transition is excluded outright.
    public static let defaultTransitionS = 30
    /// Default width of the `recovery` window measured from the transition (not from the end of
    /// `transition`): seconds 30-120 are "settling but not yet steady".
    public static let defaultRecoveryS = 120

    /// Classify a moment from how long ago the nearest transition behind it was.
    ///
    /// `secondsSinceTransition` is nil when no transition is known in the lookback the caller supplied —
    /// treated as `steadyState` rather than excluded, the same "absence of evidence is not evidence of a
    /// transition" convention `HRVAnalyzer.beatAccurateFraction` uses: a caller that never saw a transition
    /// event has no reason to assume one just happened. A negative value (a transition the caller computed
    /// as being AFTER the moment in question) is defensively treated the same way.
    public static func phase(secondsSinceTransition: Int?, transitionS: Int = defaultTransitionS,
                             recoveryS: Int = defaultRecoveryS) -> ActivityPhysiologyPhase {
        guard let s = secondsSinceTransition, s >= 0 else { return .steadyState }
        if s < transitionS { return .transition }
        if s < recoveryS { return .recovery }
        return .steadyState
    }

    /// Classify a WINDOW (not a moment): the phase of `[start, end)` is decided by the transition nearest
    /// its START, because a transition anywhere inside the window mixes two behaviours into one reading.
    ///
    /// - `eventsAvailable == false` → `.unknown`: there was no event data to look at, so the absence of an
    ///   event proves nothing. The nil-means-steady convention above applies only when the caller DID have
    ///   decoded events for the span.
    /// - `transitionsInWindow > 0` → `.transition`, however long the window ran after it.
    /// - otherwise `phase(secondsSinceTransition:)` measured from the window start.
    public static func windowPhase(secondsSinceTransitionAtStart: Int?, transitionsInWindow: Int,
                                   eventsAvailable: Bool, transitionS: Int = defaultTransitionS,
                                   recoveryS: Int = defaultRecoveryS) -> ActivityPhysiologyPhase {
        guard eventsAvailable else { return .unknown }
        if transitionsInWindow > 0 { return .transition }
        return phase(secondsSinceTransition: secondsSinceTransitionAtStart, transitionS: transitionS,
                     recoveryS: recoveryS)
    }

    /// Postural transitions (sit/stand/lie/get up) change the orthostatic load directly; locomotion
    /// starts/stops are reported separately so a reader can tell "just sat down" from "just stopped walking".
    public static func isPostural(_ kind: ActivityTransitionKind) -> Bool {
        switch kind {
        case .sitToStandLike, .standToSitLike, .lyingDownLike, .gettingUpLike: return true
        case .walkStart, .walkStop, .runStart, .runStop: return false
        }
    }

    /// Whether `kind` ends a bout of locomotion (the wake behind it is exertional, not orthostatic).
    public static func isLocomotionStop(_ kind: ActivityTransitionKind) -> Bool {
        kind == .walkStop || kind == .runStop
    }

    // MARK: Kind-aware recovery (D8-08)

    /// How long the wake behind a transition lasts, by what kind of transition it was and what the reading
    /// is for. One 30/120 s pair for every kind (the original rule) is right for heart rate after a change of
    /// position, but not for HRV, and not after a walk or a run:
    ///   - a change of position settles heart rate in 1-2 min (Bourdillon 2017), but the autonomic balance
    ///     behind HRV takes up to ~5 min to re-equilibrate (Watanabe 2007), so a resting HRV baseline waits
    ///     300 s after one;
    ///   - stopping a walk leaves an exertional wake of at least ~5 min in both HR and HRV, and a long bout
    ///     (>= 30 min) or any run leaves one of ~30 min (Stanley 2013: vagal reactivation after sustained effort
    ///     is slow), so those wait 1800 s.
    /// A locomotion START is treated like a change of position: whatever follows a walk start is either
    /// still locomotion (which the activity lookup sees) or a stop event with its own, longer recovery.
    public struct RecoveryPolicy: Equatable, Sendable {
        /// Width of the `transition` phase after any event.
        public var transitionS: Int
        /// Recovery after a change of position (and after a locomotion start), measured from the event.
        public var posturalRecoveryS: Int
        /// Recovery after an ordinary walk stops.
        public var locomotionStopRecoveryS: Int
        /// Recovery after a long bout (`longBoutS` or more) or a run.
        public var longBoutRecoveryS: Int
        /// Bout length from which the long-bout recovery applies.
        public var longBoutS: Int

        public init(transitionS: Int = ActivityTransitionProximity.defaultTransitionS,
                    posturalRecoveryS: Int, locomotionStopRecoveryS: Int = 300,
                    longBoutRecoveryS: Int = 1_800, longBoutS: Int = 1_800) {
            self.transitionS = transitionS
            self.posturalRecoveryS = posturalRecoveryS
            self.locomotionStopRecoveryS = locomotionStopRecoveryS
            self.longBoutRecoveryS = longBoutRecoveryS
            self.longBoutS = longBoutS
        }

        /// Heart rate: 120 s after a change of position, 300 s after a walk.
        public static let heartRate = RecoveryPolicy(posturalRecoveryS: ActivityTransitionProximity.defaultRecoveryS)
        /// A resting HRV baseline observation: 300 s after a change of position, 300 s after a walk.
        public static let hrvBaseline = RecoveryPolicy(posturalRecoveryS: 300)

        /// Recovery after an event of `kind`. `boutS` is the length of the locomotion bout a stop ended, when
        /// known; `running` says the bout was a run (a `runStop` always is).
        public func recoveryS(for kind: ActivityTransitionKind, boutS: Int? = nil, running: Bool = false) -> Int {
            guard ActivityTransitionProximity.isLocomotionStop(kind) else { return posturalRecoveryS }
            return locomotionRecoveryS(boutS: boutS, running: running || kind == .runStop)
        }

        /// Recovery after a locomotion bout of `boutS` seconds ended (unknown length → the ordinary walk rule).
        public func locomotionRecoveryS(boutS: Int?, running: Bool) -> Int {
            if running { return longBoutRecoveryS }
            if let boutS, boutS >= longBoutS { return longBoutRecoveryS }
            return locomotionStopRecoveryS
        }

        /// The history a caller must have looked through, with no event found, before "no event" can be read
        /// as steady state: the longest recovery an UNDOSED event could still be in. A long-bout wake is not
        /// covered here; the activity lookup's locomotion lookback guards that (see `HRVWindowBuilder`).
        public var requiredLookbackS: Int { max(posturalRecoveryS, locomotionStopRecoveryS) }
    }

    /// One event behind a window, with what is known about the bout it ended.
    public struct PrecedingEvent: Equatable, Sendable {
        public var kind: ActivityTransitionKind
        /// Seconds from the event to the moment/window start (>= 0).
        public var secondsBefore: Int
        public var boutS: Int?
        public var running: Bool
        public init(kind: ActivityTransitionKind, secondsBefore: Int, boutS: Int? = nil, running: Bool = false) {
            self.kind = kind; self.secondsBefore = secondsBefore; self.boutS = boutS; self.running = running
        }
    }

    /// Kind-aware window phase: like `windowPhase(secondsSinceTransitionAtStart:...)`, but every event
    /// behind the window is judged by ITS OWN recovery (`policy.recoveryS(for:)`), and the worst phase wins
    /// (a stand-up 200 s ago is still recovering for HRV even when a later walk-start was 40 s ago).
    ///
    /// - `eventsAvailable == false` → `.unknown`;
    /// - `transitionsInWindow > 0` → `.transition`;
    /// - any preceding event still inside its transition / recovery → that phase;
    /// - otherwise `.steadyState`, unless `lookbackS` (how far before the window start the caller's event data
    ///   reaches) is shorter than `policy.requiredLookbackS`: then a transition just before the data began
    ///   cannot be ruled out, and the phase is `.unknown`. nil `lookbackS` means "unbounded" (the caller
    ///   vouches for its history).
    public static func windowPhase(preceding: [PrecedingEvent], transitionsInWindow: Int, eventsAvailable: Bool,
                                   lookbackS: Int?, policy: RecoveryPolicy) -> ActivityPhysiologyPhase {
        guard eventsAvailable else { return .unknown }
        if transitionsInWindow > 0 { return .transition }
        var worst = ActivityPhysiologyPhase.steadyState
        for e in preceding where e.secondsBefore >= 0 {
            let p = phase(secondsSinceTransition: e.secondsBefore, transitionS: policy.transitionS,
                          recoveryS: policy.recoveryS(for: e.kind, boutS: e.boutS, running: e.running))
            if p == .transition { return .transition }
            if p == .recovery { worst = .recovery }
        }
        if worst == .steadyState, let lookbackS, lookbackS < policy.requiredLookbackS { return .unknown }
        return worst
    }
}
