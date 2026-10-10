import Foundation

/// The exercise-session context of one Watchdog window (rule exercise-session-2): the phase of each window minute,
/// the sessions in the evidence history behind it, and the in-session safety ceiling. Built by the app from up to
/// 4 hours of per-minute evidence (`WatchdogService`), or by tests from a tape. It selects which reference a minute
/// is compared with; it never mutes a check and never widens a safety bound.
///
/// A workout the wearer logged (workout mode, docs/context-watchdog/WORKOUTS.md) is an observed label, not an
/// inference: its minutes are strong movement evidence for the rule, and every window minute it covers is `session`
/// from its first minute, without waiting for movement or load to open one. The rule itself is unchanged; the safety
/// bounds (the in-session ceiling, the brady and SpO2 extremes) still judge those minutes.
public struct WatchdogExerciseContext: Equatable, Sendable {
    public var rule: String
    /// One phase per window minute (aligned with `WatchdogWindow.hr`).
    public var phases: [ExerciseSessionPhase]
    /// Sessions found in the evidence history, oldest first.
    public var spans: [ExerciseSessionSpan]
    /// The HR the rule's load check used, and where it came from.
    public var restReference: Double
    public var restBasis: String
    /// In-session ceiling (bpm): above it for `ceilingSustainMinutes` is a safety extreme even inside a session.
    public var hrCeiling: Double
    public var hrCeilingBasis: String
    /// The routine cluster the newest session matches (interpretation and display only).
    public var routine: ExerciseRoutine.Cluster?
    /// Workouts the wearer logged that overlap the evidence history (oldest first).
    public var logged: [LoggedWorkoutSpan] = []

    public init(rule: String = ExerciseSessionRule.rule, phases: [ExerciseSessionPhase], spans: [ExerciseSessionSpan],
                restReference: Double, restBasis: String, hrCeiling: Double, hrCeilingBasis: String,
                routine: ExerciseRoutine.Cluster? = nil) {
        self.rule = rule; self.phases = phases; self.spans = spans
        self.restReference = restReference; self.restBasis = restBasis
        self.hrCeiling = hrCeiling; self.hrCeilingBasis = hrCeilingBasis; self.routine = routine
    }

    public static let historySeconds = 4 * 3600
    public static let ceilingSustainMinutes = 5
    /// Used when nothing else is known: above every adult's predicted maximum for at least 5 minutes.
    public static let defaultCeiling = 200.0
    /// A personal ceiling needs this many sessions in the routine cluster.
    public static let personalCeilingSessions = 7

    /// The phase of the window minute starting at `minuteUnix`.
    public func phase(at index: Int) -> ExerciseSessionPhase {
        index >= 0 && index < phases.count ? phases[index] : .none
    }

    /// The logged workout covering the minute starting at `minuteUnix`, if any.
    public func loggedWorkout(at minuteUnix: Int) -> LoggedWorkoutSpan? {
        LoggedWorkoutSpan.span(at: minuteUnix, in: logged)
    }

    /// Seconds from the governing session's last evidence minute to `unix` (recovery minutes only).
    public func secondsSinceSessionEnd(at unix: Int) -> Int? {
        guard let s = ExerciseSessionRule.span(at: unix, in: spans), !s.open, unix > s.endUnix else { return nil }
        return unix - (s.endUnix + 60)
    }

    // MARK: Build

    /// - Parameters:
    ///   - minutes: per-minute evidence for up to `historySeconds` before `nowUnix`.
    ///   - windowStart / seqLen: the Watchdog window the phases are for.
    ///   - hrMax: the person's maximum HR (`Profile.hrMax`: their override, else 208 − 0.7·age); `hrMaxFromFormula`
    ///     says which, because a formula maximum gets +5 bpm of tolerance.
    ///   - logged: workouts the wearer logged (workout mode), running ones up to now. Their minutes are strong
    ///     evidence for the rule, and the window minutes they cover are `session`.
    public static func build(minutes: [ExerciseSessionMinute], windowStart: Int, seqLen: Int, nowUnix: Int,
                             evaluations: [LBEvaluation], hrMax: Double? = nil, hrMaxFromFormula: Bool = true,
                             routine: ExerciseRoutine? = nil, logged: [LoggedWorkoutSpan] = [],
                             calendar: Calendar = .current) -> WatchdogExerciseContext {
        let logged = logged.filter { $0.endUnix > $0.startUnix }.sorted { $0.startUnix < $1.startUnix }
        let evidence = withLoggedEvidence(minutes, logged: logged)
        let (rest, restBasis) = restReference(evaluations: evaluations, minutes: evidence)
        let spans = ExerciseSessionRule.sessions(minutes: evidence, restReference: rest, nowUnix: nowUnix)
        var phases = ExerciseSessionRule.phases(spans, fromUnix: windowStart,
                                                toUnix: windowStart + seqLen * WatchdogConfig.gridSeconds)
        for i in phases.indices where LoggedWorkoutSpan.span(at: windowStart + i * WatchdogConfig.gridSeconds,
                                                              in: logged) != nil {
            phases[i] = .session
        }
        let cluster = spans.last.flatMap { routine?.match(startUnix: $0.startUnix, calendar: calendar) }
        let (ceiling, ceilingBasis) = self.ceiling(hrMax: hrMax, fromFormula: hrMaxFromFormula, routine: routine)
        var ex = WatchdogExerciseContext(phases: phases, spans: spans, restReference: rest, restBasis: restBasis,
                                         hrCeiling: ceiling, hrCeilingBasis: ceilingBasis, routine: cluster)
        ex.logged = logged
        return ex
    }

    /// The evidence minutes with every history minute a logged workout covers made strong: the wearer said they were
    /// exercising. Minutes the history does not hold are not invented, so a logged workout never stretches the grid.
    static func withLoggedEvidence(_ minutes: [ExerciseSessionMinute],
                                   logged: [LoggedWorkoutSpan]) -> [ExerciseSessionMinute] {
        guard !logged.isEmpty else { return minutes }
        return minutes.map { m in
            guard !m.strong, LoggedWorkoutSpan.span(at: m.minuteUnix, in: logged) != nil else { return m }
            var strong = m
            strong.strong = true
            return strong
        }
    }

    /// Rest reference for the load check, in order: the established awake-rest HR centre; the established sleep resting
    /// HR + 10; the median HR of minutes with no movement evidence (and none in the 20 minutes before) in the history;
    /// 70 bpm.
    public static func restReference(evaluations: [LBEvaluation],
                                     minutes: [ExerciseSessionMinute]) -> (Double, String) {
        if let ev = evaluations.first(where: { $0.series == .awakeRestHR }), ev.establishedLong, !ev.stale,
           let c = ev.copyLong?.center {
            return (c, "awake_rest_reference")
        }
        if let ev = evaluations.first(where: { $0.series == .sleepRHR }), ev.establishedLong, !ev.stale,
           let c = ev.copyLong?.center {
            return (c + 10, "sleep_rhr_plus_10")
        }
        let sorted = minutes.sorted { $0.minuteUnix < $1.minuteUnix }
        var lastEvidence = Int.min / 2
        var still: [Double] = []
        for m in sorted {
            if m.evidence { lastEvidence = m.minuteUnix; continue }
            if m.minuteUnix - lastEvidence > 20 * 60, let h = m.hr { still.append(h) }
        }
        if still.count >= 10, let med = ExerciseSessionRule.median(still) {
            return (med, "recent_still_median")
        }
        return (70, "default_70")
    }

    /// The in-session ceiling: the person's maximum HR (+5 when it is the age formula), lowered to their own session
    /// peaks + 10 once a routine cluster holds `personalCeilingSessions` sessions; 200 bpm when nothing is known.
    public static func ceiling(hrMax: Double?, fromFormula: Bool, routine: ExerciseRoutine?) -> (Double, String) {
        var bound = defaultCeiling
        var basis = "default_200"
        if let m = hrMax, m >= 120, m <= 230 {
            bound = fromFormula ? m + 5 : m
            basis = fromFormula ? "age_formula_plus_5" : "profile_hr_max"
        }
        let personal = routine?.clusters
            .filter { $0.sessions >= personalCeilingSessions }
            .compactMap(\.hrPeakP90).max()
        if let p = personal, p + 10 < bound {
            return (p + 10, "own_session_peaks_plus_10")
        }
        return (bound, basis)
    }
}
