import Foundation

// DayStretchLayout.swift — how the Heart rate page arranges a day's stretches.
//
// A busy day has a couple of hundred stretches. The page leads with the few that matter most (the newest),
// and keeps the rest out of the way, grouped by the part of the day they started in.

/// A part of the day, by the local hour a stretch started in.
public enum StretchDayPart: Int, CaseIterable, Comparable, Sendable {
    /// 00:00 to 05:00.
    case overnight
    /// 05:00 to 12:00.
    case morning
    /// 12:00 to 17:00.
    case midday
    /// 17:00 to 24:00.
    case evening

    public static func of(_ ts: Int, calendar: Calendar = .current) -> StretchDayPart {
        let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
        switch hour {
        case ..<5: return .overnight
        case ..<12: return .morning
        case ..<17: return .midday
        default: return .evening
        }
    }

    public static func < (a: StretchDayPart, b: StretchDayPart) -> Bool { a.rawValue < b.rawValue }
}

/// The newest few stretches, then every other one grouped by part of the day.
public struct DayStretchLayout: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public let part: StretchDayPart
        /// Newest first.
        public let stretches: [ActivityEpisode]
    }

    public static let recentCount = 5
    /// Shorter stretches are blips between two longer ones, and are left off the lists.
    public static let minimumSeconds = 60

    /// The newest stretches, newest first.
    public let recent: [ActivityEpisode]
    /// The rest, the latest part of the day first. A part with nothing in it is left out.
    public let earlier: [Group]

    public var count: Int { recent.count + earlier.reduce(0) { $0 + $1.stretches.count } }

    public init(episodes: [ActivityEpisode], recentCount: Int = DayStretchLayout.recentCount,
                minimumSeconds: Int = DayStretchLayout.minimumSeconds, calendar: Calendar = .current) {
        let ordered = episodes
            .filter { $0.durationSeconds >= minimumSeconds }
            .sorted { $0.start != $1.start ? $0.start > $1.start : $0.end > $1.end }
        recent = Array(ordered.prefix(max(0, recentCount)))
        let rest = ordered.dropFirst(max(0, recentCount))
        let byPart = Dictionary(grouping: rest) { StretchDayPart.of($0.start, calendar: calendar) }
        earlier = byPart.keys.sorted(by: >).map { Group(part: $0, stretches: byPart[$0] ?? []) }
    }
}

/// The posture changes the decoder flagged, and which of them belong with a set of stretches.
public enum PositionChanges {
    /// Below this the decoder is guessing: the event is stored but not shown as having happened.
    public static let minimumProbability = 0.40
    /// How far outside a stretch an event can fall and still belong to it. A change of position happens at the
    /// edge between two stretches, so it is as much the end of one as the start of the next.
    public static let slackSeconds = 90

    /// Every event worth showing, newest first.
    public static func all(_ events: [ActivityTransitionEvent],
                           minimumProbability: Double = PositionChanges.minimumProbability)
        -> [ActivityTransitionEvent] {
        events.filter { $0.probability >= minimumProbability }.sorted { $0.ts > $1.ts }
    }

    /// The events worth showing that fall inside, or within `slackSeconds` of, any of `stretches`. Newest first.
    public static func near(_ stretches: [ActivityEpisode], in events: [ActivityTransitionEvent],
                            minimumProbability: Double = PositionChanges.minimumProbability,
                            slackSeconds: Int = PositionChanges.slackSeconds) -> [ActivityTransitionEvent] {
        all(events, minimumProbability: minimumProbability).filter { event in
            stretches.contains { event.ts >= $0.start - slackSeconds && event.ts <= $0.end + slackSeconds }
        }
    }
}
