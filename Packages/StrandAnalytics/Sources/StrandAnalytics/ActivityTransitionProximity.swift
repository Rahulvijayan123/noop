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
}
