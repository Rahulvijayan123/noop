import Foundation

// MARK: - Strap placement model (G4)

/// Manual strap placement (docs/core-plumbing/spec.md §6). `unknown` is a first-class value:
/// unannotated history stays UNKNOWN and is never backfilled with today's setting.
public enum StrapPlacement: String, Codable, CaseIterable, Sendable, Hashable {
    case wrist
    case bicep
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .wrist: return String(localized: "Wrist")
        case .bicep: return String(localized: "Bicep")
        case .other: return String(localized: "Other")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

/// One effective-dated placement interval. Half-open `[effectiveStart, effectiveEnd)` everywhere;
/// a nil `effectiveEnd` is an open interval. `revision` is a per-owner monotonic counter bumped on
/// every declaration/correction so a correction never silently rewrites a past row.
public struct PlacementInterval: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var deviceId: String?
    public var placement: StrapPlacement
    public var effectiveStart: Date
    public var effectiveEnd: Date?
    public var recordedAt: Date
    public var source: String
    public var revision: Int64

    public init(id: UUID = UUID(), deviceId: String?, placement: StrapPlacement,
                effectiveStart: Date, effectiveEnd: Date?, recordedAt: Date = Date(),
                source: String = "user", revision: Int64 = 1) {
        self.id = id
        self.deviceId = deviceId
        self.placement = placement
        self.effectiveStart = effectiveStart
        self.effectiveEnd = effectiveEnd
        self.recordedAt = recordedAt
        self.source = source
        self.revision = revision
    }

    /// Whether this interval covers `at` (half-open `[start, end)`).
    public func contains(_ at: Date) -> Bool {
        effectiveStart <= at && (effectiveEnd == nil || effectiveEnd! > at)
    }

    /// Overlap with a half-open window `[windowStart, windowEnd)`.
    public func overlaps(windowStart: Date, windowEnd: Date) -> Bool {
        effectiveStart < windowEnd && (effectiveEnd == nil || effectiveEnd! > windowStart)
    }
}

/// A recorded "set current placement" change, the offline journal entry replayed to the server in
/// recorded order. The interval table is the folded read model; these rows are the replay log.
public struct PlacementChange: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var deviceId: String?
    public var placement: StrapPlacement
    public var effectiveStart: Date
    public var recordedAt: Date
    public var synced: Bool

    public init(id: UUID = UUID(), deviceId: String?, placement: StrapPlacement,
                effectiveStart: Date, recordedAt: Date = Date(), synced: Bool = false) {
        self.id = id
        self.deviceId = deviceId
        self.placement = placement
        self.effectiveStart = effectiveStart
        self.recordedAt = recordedAt
        self.synced = synced
    }
}

// MARK: - Pure interval folding (mirrors set_placement_interval on the server)

/// Pure, deterministic placement-interval operations. No persistence, no clock reads — every input
/// and output is explicit so the correction semantics are unit-testable in isolation and the local
/// SQLite store and the server RPC share one shape.
public enum PlacementIntervals {
    /// The interval covering `at` in `deviceScope` (half-open), or nil when history is unannotated.
    public static func active(_ intervals: [PlacementInterval], at: Date,
                              deviceId: String?) -> PlacementInterval? {
        let scope = deviceId ?? ""
        return intervals.first { ($0.deviceId ?? "") == scope && $0.contains(at) }
    }

    /// Fold one "set current placement at `at`" declaration into an interval set. Returns the new
    /// set and the interval the declaration produced (created, or the same-start row it replaced).
    ///
    /// Semantics (identical to `set_placement_interval`):
    ///  1. the interval strictly containing `at` is closed there (`[start, at)`);
    ///  2. an interval that starts exactly at `at` is the degenerate close case and is replaced in
    ///     place (placement/source/revision bump, its end kept);
    ///  3. the new open interval is capped at the next interval's start, so a future-dated interval
    ///     (only possible via a server pull) is never overwritten.
    /// History is never silently rewritten: rows are cut or superseded by the explicit declaration,
    /// never deleted.
    public static func applying(_ intervals: [PlacementInterval],
                                set placement: StrapPlacement,
                                at: Date,
                                deviceId: String?,
                                recordedAt: Date = Date(),
                                nextRevision: Int64) -> (intervals: [PlacementInterval],
                                                         changed: PlacementInterval?) {
        let scope = deviceId ?? ""
        var out = intervals.filter { ($0.deviceId ?? "") == scope }
        let untouched = intervals.filter { ($0.deviceId ?? "") != scope }

        // 1. Close the interval strictly containing `at`.
        for i in out.indices where out[i].effectiveStart < at && out[i].contains(at) {
            out[i] = PlacementInterval(id: out[i].id, deviceId: out[i].deviceId,
                                       placement: out[i].placement,
                                       effectiveStart: out[i].effectiveStart,
                                       effectiveEnd: at,
                                       recordedAt: out[i].recordedAt,
                                       source: out[i].source, revision: out[i].revision)
        }

        // 2. Degenerate same-start declaration: replace in place (a prior declaration superseded).
        if let idx = out.firstIndex(where: { $0.effectiveStart == at
            && ($0.effectiveEnd == nil || $0.effectiveEnd! > at) }) {
            let replaced = PlacementInterval(id: out[idx].id, deviceId: out[idx].deviceId,
                                             placement: placement,
                                             effectiveStart: out[idx].effectiveStart,
                                             effectiveEnd: out[idx].effectiveEnd,
                                             recordedAt: recordedAt,
                                             source: "user", revision: nextRevision)
            out[idx] = replaced
            return (out + untouched, replaced)
        }

        // 3. New open interval, capped at the next future-dated interval so nothing overlaps.
        let nextStart = out.map(\.effectiveStart).filter { $0 > at }.min()
        let created = PlacementInterval(deviceId: deviceId, placement: placement,
                                        effectiveStart: at,
                                        effectiveEnd: nextStart,
                                        recordedAt: recordedAt,
                                        source: "user", revision: nextRevision)
        out.append(created)
        return (out + untouched, created)
    }

    /// Next per-owner revision counter value.
    public static func nextRevision(of intervals: [PlacementInterval]) -> Int64 {
        (intervals.map(\.revision).max() ?? 0) + 1
    }
}

// MARK: - Wear-state interval reconstruction (G3)

/// Deterministic half-open wear-state spans reconstructed from WRIST_ON/WRIST_OFF event rows
/// (kind strings "WRIST_ON(9)" / "WRIST_OFF(10)", prefix-matched). Gaps carry no span: absence of
/// evidence is UNKNOWN, never a guessed state. Duplicate events (ON while on, OFF while off) are
/// coalesced; out-of-order events are sorted. Only events inside `[from, to)` are considered, so a
/// stale pre-window OFF can never paint the start of a window off-body, and an open tail (last
/// event with no partner) extends to `to`.
public enum WearStateSpans {
    public enum State: Equatable, Sendable {
        case on
        case off
    }

    /// One half-open `[start, end)` span with a single state.
    public struct Span: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let state: State
        public init(start: Int, end: Int, state: State) {
            self.start = start; self.end = end; self.state = state
        }
    }

    /// Reconstruct spans from raw WRIST event rows over `[from, to)`.
    public static func reconstruct(events: [(ts: Int, kind: String)], from: Int, to: Int) -> [Span] {
        guard to > from else { return [] }
        let wear = events
            .filter { $0.ts >= from && $0.ts < to }
            .filter { $0.kind.hasPrefix("WRIST_ON") || $0.kind.hasPrefix("WRIST_OFF") }
            .sorted { lhs, rhs in
                // Deterministic tie-break at equal timestamps (audit-g34-g7-context F7): WRIST_OFF
                // sorts before WRIST_ON so an OFF+ON pair at the same second yields "on from then",
                // matching `AnalyticsEngine.offWristIntervals` (OFF opens, ON closes, zero-length
                // skipped). Swift's sort is not contractually stable, so the secondary key is what
                // makes the reconstruction reproducible.
                if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
                return lhs.kind.hasPrefix("WRIST_OFF") && rhs.kind.hasPrefix("WRIST_ON")
            }
        var spans: [Span] = []
        var state: State? = nil
        var spanStart = from
        for e in wear {
            let on = e.kind.hasPrefix("WRIST_ON")
            let next: State = on ? .on : .off
            if state == next { continue }
            if let current = state, e.ts > spanStart {
                spans.append(Span(start: spanStart, end: e.ts, state: current))
            }
            state = next
            spanStart = e.ts
        }
        if let current = state, to > spanStart {
            spans.append(Span(start: spanStart, end: to, state: current))
        }
        return spans
    }
}
