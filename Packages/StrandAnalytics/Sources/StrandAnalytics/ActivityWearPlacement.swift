import Foundation

// ActivityWearPlacement.swift — where on the body the strap is worn, as the activity decoder reads it (hsmm-2.0).
//
// Every posture cue the decoder had before hsmm-2.0 assumed a WRIST: the strap's +x axis is the forearm, a hanging
// forearm leans standing, a desk-like hand pattern leans sitting, "standing up lowers the hand", and HART's fine
// sit / stand rows were trained on wrist (WISDM) data. On the upper arm none of that holds. The humerus hangs
// vertically whether its owner sits or stands (the owner's 2026-10-09 afternoon: 90 seated minutes whose held
// orientation sat 10–19° from their own standing calibration and 22–42° from their sitting one), the hand pattern is
// not visible, and the wrist-trained heads have never seen the frame. So on a non-wrist placement the decoder drops
// the seated-versus-upright part of those cues and keeps everything else they say (moving versus still, lying versus
// upright, which transition mode is plausible). With nothing else speaking, a still upper arm reads "Still, sitting
// or standing" — the honest answer — instead of whatever a wrist rule guessed.
//
// Placement is the wearer's own declaration (`placement_intervals`, Settings → Wear placement). An interval that is
// missing or `unknown` keeps the wrist reading every decoder before hsmm-2.0 used, so a wearer who never declared a
// placement decodes exactly as before.

/// Where the strap is worn. Raw values match `public.placement_intervals.placement`.
public enum ActivityWearPlacement: String, Codable, CaseIterable, Sendable, Hashable {
    case wrist
    case bicep
    case other
    case unknown

    /// Whether the decoder's wrist-geometry posture cues (forearm-axis orientation, the hand pattern, a shift's
    /// forearm direction, wrist-trained learned heads) may speak about sitting versus standing. Only a wrist, or a
    /// placement nobody declared (the pre-hsmm-2.0 reading), keeps them.
    public var wristPostureCues: Bool { self == .wrist || self == .unknown }

    /// Which calibration a second worn here uses: an undeclared placement reads as the wrist (as the decoder does).
    public var calibrationKey: String {
        switch self {
        case .wrist, .unknown: return "wrist"
        case .bicep: return "bicep"
        case .other: return "other"
        }
    }

    /// A declared placement string as stored (case-insensitive); anything unrecognised is `unknown`.
    public init(declared: String?) {
        self = declared.flatMap { ActivityWearPlacement(rawValue: $0.lowercased()) } ?? .unknown
    }
}

/// One declared placement interval, half-open `[start, end)` in Unix seconds (`end` nil = still current).
public struct ActivityPlacementSpan: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int?
    public var placement: ActivityWearPlacement

    public init(start: Int, end: Int?, placement: ActivityWearPlacement) {
        self.start = start; self.end = end; self.placement = placement
    }

    public func contains(_ ts: Int) -> Bool { start <= ts && (end.map { ts < $0 } ?? true) }
}

extension ActivityDecoderConfig {
    /// The placement covering `ts`: the latest-starting declared span that contains it, `unknown` when none does.
    public func placement(at ts: Int) -> ActivityWearPlacement {
        guard let spans = placements, !spans.isEmpty else { return .unknown }
        var best: ActivityPlacementSpan?
        for s in spans where s.contains(ts) {
            if best == nil || s.start >= best!.start { best = s }
        }
        return best?.placement ?? .unknown
    }

    /// The declared spans clipped to `[from, to)` and reduced to what changes the decode: spans whose placement
    /// keeps the wrist reading are dropped, so a config for a wrist-only (or undeclared) day equals one with no
    /// placements at all (same `cacheTag`, same snapshots). Sorted by start.
    public static func decodingPlacements(_ spans: [ActivityPlacementSpan], from: Int, to: Int) -> [ActivityPlacementSpan]? {
        // A later declaration overrides an earlier one where they overlap, so resolve before filtering: the spans
        // kept are exactly the stretches of [from, to) whose resolved placement is non-wrist.
        var cuts = Set([from, to])
        for s in spans {
            if s.start > from && s.start < to { cuts.insert(s.start) }
            if let e = s.end, e > from, e < to { cuts.insert(e) }
        }
        let bounds = cuts.sorted()
        var probe = ActivityDecoderConfig()
        probe.placements = spans
        var out: [ActivityPlacementSpan] = []
        for i in 0..<(bounds.count - 1) {
            let p = probe.placement(at: bounds[i])
            guard !p.wristPostureCues else { continue }
            if let last = out.last, last.end == bounds[i], last.placement == p {
                out[out.count - 1].end = bounds[i + 1]
            } else {
                out.append(ActivityPlacementSpan(start: bounds[i], end: bounds[i + 1], placement: p))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// `-pl<hash>` for the cache tag while any decoding placement is set (FNV-1a over the spans).
    var placementTag: String? {
        guard let spans = placements, spans.contains(where: { !$0.placement.wristPostureCues }) else { return nil }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) { for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 } }
        for s in spans { mix("\(s.start)|\(s.end.map(String.init) ?? "-")|\(s.placement.rawValue);") }
        return String(String(h, radix: 16).prefix(10))
    }
}
