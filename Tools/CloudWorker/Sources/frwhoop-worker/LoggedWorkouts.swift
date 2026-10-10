import Foundation
import StrandAnalytics

// LoggedWorkouts.swift — workout mode's typed log for the activity lane (docs/context-watchdog/WORKOUTS.md).
//
// The lane has always read the strap's workout records from `public.sessions` (any workout or manual workout, its
// sport name from the structured push) for the epochs' `exercise_session` and the decoder's workout kind. Workout mode
// adds `public.user_workouts` (20261009170000): a running workout, its catalogue type, and edits after the fact. The
// lane reads it through `internal.logged_workouts_v1` (the list every server pipeline reads), merges it with the
// session records (a record a workout-mode row holds gives way to it, and the row carries the type's stored sport name
// so the shared decoder reads the type's kind), and records the overlapping workouts on the ElderNet gait row so its
// gait windows are labelled against what the wearer was doing. Model outputs are never changed.

/// One workout the wearer logged in workout mode.
struct LoggedWorkout: Equatable, Encodable {
    var start: Int
    var end: Int
    var typeId: String
    /// The workout's client id (its row in `public.user_workouts`).
    var ref: String

    var type: WorkoutTypeCatalog.Entry? { WorkoutTypeCatalog.entry(id: typeId) }
}

enum LoggedWorkouts {
    /// Workout-mode rows only: the manual sessions the function also lists are already among the session records.
    static let sql = """
        select extract(epoch from start_at)::bigint::text as s, extract(epoch from end_at)::bigint::text as e,
               coalesce(workout_type, '') as type, ref
          from internal.logged_workouts_v1($1::uuid, $2::uuid, to_timestamp($3::bigint), to_timestamp($4::bigint))
         where basis = 'user_workout'
         order by start_at, ref
        """

    /// A session record within this many seconds of a workout-mode row's start is that workout.
    static let sameWorkoutSeconds = 120

    /// The logged workouts overlapping `[from, to)`. A database without 20261009170000 (or a function it cannot run)
    /// has none: the lane keeps reading the session records alone. Only a lost connection propagates.
    static func load(db: PostgresClient, user: String, device: String, from: Int, to: Int) throws -> [LoggedWorkout] {
        do {
            let rows = try db.isolatingFailures { try db.query(sql, [user, device, String(from), String(to)]) }
            return rows.compactMap { r in
                guard let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? ""), e > s, let type = r["type"],
                      WorkoutTypeCatalog.entry(id: type) != nil else { return nil }
                return LoggedWorkout(start: s, end: e, typeId: type, ref: r["ref"] ?? "")
            }
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            return []
        }
    }

    /// The session records plus the logged workouts: a record a logged workout holds (same start within
    /// `sameWorkoutSeconds`) gives way to it, and a logged workout's sport is its type's stored sport name.
    static func merge(sessions: [(start: Int, end: Int, sport: String)],
                      logged: [LoggedWorkout]) -> [(start: Int, end: Int, sport: String)] {
        let kept = sessions.filter { s in !logged.contains { abs($0.start - s.start) <= sameWorkoutSeconds } }
        let typed = logged.compactMap { w in w.type.map { (start: w.start, end: w.end, sport: $0.sportName) } }
        return (kept + typed).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// What the ElderNet gait row says about each logged workout overlapping its windows: the type and its attributes,
    /// the windows inside it, how many of them ElderNet called gait, and what that gait means for the type
    /// (`expected_gait` for a walk or run, `unexpected_gait` for a stationary or cycling workout, `unlabelled` for a
    /// mixed one). A window belongs to the workout holding its midpoint.
    struct GaitContext: Equatable, Encodable {
        var start: Int
        var end: Int
        var type: String
        var environment: String
        var locomotion: String
        var effort: String
        var gaitExpected: Bool
        var armMotion: String
        var stepsExpected: Bool
        var nWindows: Int
        var nGait: Int
        var gaitLabel: String

        enum CodingKeys: String, CodingKey {
            case start, end, type, environment, locomotion, effort
            case gaitExpected = "gait_expected", armMotion = "arm_motion", stepsExpected = "steps_expected"
            case nWindows = "n_windows", nGait = "n_gait", gaitLabel = "gait_label"
        }
    }

    static func gaitContext(workouts: [LoggedWorkout], windows: [GaitQualityWindow]) -> [GaitContext] {
        workouts.compactMap { w in
            guard let t = w.type else { return nil }
            let inside = windows.filter { let mid = ($0.startTs + $0.endTs) / 2; return mid >= w.start && mid < w.end }
            return GaitContext(start: w.start, end: w.end, type: t.id, environment: t.environment.rawValue,
                               locomotion: t.locomotion.rawValue, effort: t.effort.rawValue,
                               gaitExpected: t.gaitExpected, armMotion: t.armMotion.rawValue,
                               stepsExpected: t.stepsExpected, nWindows: inside.count,
                               nGait: inside.filter(\.isGait).count, gaitLabel: t.gaitLabel)
        }
    }
}
