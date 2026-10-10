import Foundation

// WorkoutTypeCatalog.swift — catalogue `workout-types-1` (contracts/workout-types-1.json, docs/context-watchdog/WORKOUTS.md).
//
// Workout mode saves a logged workout under one of these ids. Its attributes tell the pipelines what the strap should
// see while it runs: an indoor walk expects gait and steps but no route; a ride expects no gait and fixed hands; a
// strength session is resistance, which the strap mostly sees as stillness between sets. Hand-mirrored from the
// contract and pinned to it by WorkoutTypeCatalogTests (the edge and SQL copies have their own parity tests).
//
// `sportName` is the label the workout is stored under in the phone's workout table (the app's WorkoutCatalog, a
// cross-platform value), so a typed workout reads as itself everywhere a sport name is read today. The decoder's own
// `WorkoutKind(sport:)` reads that label; `decoderKind` restates what it must read, and the parity test holds the two
// together, so the catalogue maps onto the existing sport mapping rather than beside it.

public enum WorkoutEnvironment: String, Codable, Equatable, Sendable, CaseIterable {
    case indoor, outdoor, either
}

public enum WorkoutLocomotion: String, Codable, Equatable, Sendable, CaseIterable {
    case walking, running, cycling, none, mixed
}

public enum WorkoutEffort: String, Codable, Equatable, Sendable, CaseIterable {
    case light, moderate, vigorous, resistance
}

public enum WorkoutArmMotion: String, Codable, Equatable, Sendable, CaseIterable {
    case swing, fixed, varied
}

public enum WorkoutTypeCatalog {
    public static let version = "workout-types-1"

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        /// Display name (UI copy).
        public let name: String
        /// The stored workout label (WorkoutCatalog name) and what the decoder reads the kind from.
        public let sportName: String
        public let decoderKind: WorkoutKind
        public let environment: WorkoutEnvironment
        public let locomotion: WorkoutLocomotion
        public let effort: WorkoutEffort
        public let gaitExpected: Bool
        public let armMotion: WorkoutArmMotion
        public let stepsExpected: Bool
        /// Other stored labels that resolve to this type (manual or imported rows that never had a type).
        public let sportAliases: [String]

        /// What an ElderNet gait window inside a workout of this type means: expected gait, gait the type does not
        /// allow (a stationary or cycling workout), or nothing either way (a mixed one).
        public var gaitLabel: String {
            if gaitExpected { return "expected_gait" }
            return locomotion == .none || locomotion == .cycling ? "unexpected_gait" : "unlabelled"
        }
    }

    private static func e(_ id: String, _ name: String, _ sport: String, _ kind: WorkoutKind, _ env: WorkoutEnvironment,
                          _ loco: WorkoutLocomotion, _ effort: WorkoutEffort, gait: Bool, _ arm: WorkoutArmMotion,
                          steps: Bool, aliases: [String] = []) -> Entry {
        Entry(id: id, name: name, sportName: sport, decoderKind: kind, environment: env, locomotion: loco,
              effort: effort, gaitExpected: gait, armMotion: arm, stepsExpected: steps, sportAliases: aliases)
    }

    /// In the contract's order (the picker's order).
    public static let all: [Entry] = [
        e("strength", "Strength training", "Strength", .other, .either, .none, .resistance, gait: false, .varied,
          steps: false, aliases: ["Weightlifting", "Bodybuilding", "Powerlifting", "Calisthenics"]),
        e("hiit", "HIIT / circuit", "HIIT", .other, .either, .mixed, .vigorous, gait: false, .varied, steps: true,
          aliases: ["CrossFit", "Boot camp", "Jump rope"]),
        e("indoor_walk", "Indoor walk (treadmill)", "Treadmill walk", .walking, .indoor, .walking, .moderate,
          gait: true, .varied, steps: true),
        e("outdoor_walk", "Outdoor walk", "Walking", .walking, .outdoor, .walking, .moderate, gait: true, .swing,
          steps: true, aliases: ["Nordic walking", "Rucking"]),
        e("indoor_run", "Indoor run (treadmill)", "Treadmill run", .running, .indoor, .running, .vigorous,
          gait: true, .varied, steps: true),
        e("outdoor_run", "Outdoor run", "Running", .running, .outdoor, .running, .vigorous, gait: true, .swing,
          steps: true),
        e("indoor_cycling", "Indoor cycling", "Indoor cycle", .cycling, .indoor, .cycling, .moderate, gait: false,
          .fixed, steps: false, aliases: ["Spinning"]),
        e("outdoor_cycling", "Outdoor cycling", "Cycling", .cycling, .outdoor, .cycling, .moderate, gait: false,
          .fixed, steps: false, aliases: ["Mountain biking"]),
        e("rowing", "Rowing / erg", "Row machine", .other, .either, .none, .vigorous, gait: false, .varied,
          steps: false, aliases: ["Rowing", "Kayaking"]),
        e("elliptical", "Elliptical", "Elliptical", .other, .indoor, .none, .moderate, gait: false, .varied,
          steps: false),
        e("stair_climber", "Stair climber", "Stair climber", .other, .indoor, .walking, .vigorous, gait: true,
          .varied, steps: true),
        e("swimming", "Swimming", "Pool swim", .other, .either, .none, .vigorous, gait: false, .varied, steps: false,
          aliases: ["Open-water swim"]),
        e("yoga", "Yoga", "Yoga", .other, .either, .none, .light, gait: false, .varied, steps: false),
        e("pilates", "Pilates", "Pilates", .other, .either, .none, .moderate, gait: false, .varied, steps: false),
        e("stretching", "Stretching / mobility", "Stretching", .other, .either, .none, .light, gait: false, .varied,
          steps: false),
        e("sports", "Sports (team / racket)", "Sports", .other, .either, .mixed, .vigorous, gait: true, .varied,
          steps: true, aliases: ["Tennis", "Padel", "Pickleball", "Squash", "Badminton", "Racquetball",
                                 "Table tennis", "Basketball", "Soccer", "Volleyball", "Baseball", "Softball",
                                 "Ice Hockey", "Rugby", "Cricket", "Handball", "Netball", "Lacrosse", "Field hockey",
                                 "American football", "Australian football", "Gaelic football"]),
        e("hiking", "Hiking", "Hiking", .walking, .outdoor, .walking, .moderate, gait: true, .swing, steps: true),
        e("dance", "Dance", "Dancing", .other, .either, .mixed, .moderate, gait: false, .varied, steps: true,
          aliases: ["Ballet", "Breakdancing"]),
        e("martial_arts", "Martial arts / boxing", "Martial arts", .other, .either, .mixed, .vigorous, gait: false,
          .varied, steps: false, aliases: ["Boxing", "Kickboxing", "Jiu jitsu", "Judo", "Muay Thai", "Fencing"]),
        e("other", "Other", "Other", .other, .either, .mixed, .moderate, gait: false, .varied, steps: false),
    ]

    public static let otherId = "other"

    private static let byId: [String: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func entry(id: String) -> Entry? { byId[id] }

    /// The type a stored sport label stands for: its `sportName` or one of its aliases (case-insensitive, trimmed),
    /// nil for any other label (free text stays free text; it is not guessed into a type).
    public static func resolve(sport: String) -> Entry? {
        let q = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return all.first { t in
            t.sportName.caseInsensitiveCompare(q) == .orderedSame
                || t.sportAliases.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
        }
    }
}
