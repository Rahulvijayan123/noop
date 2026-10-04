import Foundation

/// The five metrics the hosted worker publishes as a dense intraday series (`server_metric_series`).
///
/// The raw values are the names the table stores and the `scores/series` route accepts.
public enum IntradayMetric: String, CaseIterable, Sendable, Hashable {
    case hrv = "hrv_rmssd_ms"
    case restingHeartRate = "resting_hr_bpm"
    case respiratoryRate = "resp_rate_bpm"
    case steps = "steps"
    case calories = "calories_kcal"

    /// The explorer entry that shows this series. Only the strap's own entries map: an imported Apple
    /// Health step count is not something the worker computes, so it has no intraday series.
    public init?(catalogKey: String, source: String) {
        guard source == "my-whoop" else { return nil }
        switch catalogKey {
        case "hrv": self = .hrv
        case "rhr": self = .restingHeartRate
        case "resp_rate": self = .respiratoryRate
        case "steps": self = .steps
        case "energy_kcal": self = .calories
        default: return nil
        }
    }

    /// Steps and calories are additive: each bucket's value is that slice's share of the day, so the
    /// picture that matches the daily number is the running total. The others are instantaneous
    /// estimates and read as a line.
    public var isCumulative: Bool { self == .steps || self == .calories }

    public var unit: String {
        switch self {
        case .hrv: return "ms"
        case .restingHeartRate: return "bpm"
        case .respiratoryRate: return "rpm"
        case .steps: return String(localized: "steps")
        case .calories: return "kcal"
        }
    }

    public var fractionDigits: Int { self == .respiratoryRate ? 1 : 0 }

    public func format(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }
}

/// One bucket of one metric (one or five minutes wide, see `IntradaySeriesWindow.bucketSeconds(for:)`). `start` is the bucket's first second (unix).
public struct IntradaySeriesPoint: Equatable, Sendable {
    public let start: Int
    public let value: Double
    /// How many raw samples fed the bucket (beats for HRV, heart-rate samples for resting HR, …).
    public let samples: Int
    /// Share of the bucket the strap actually covered, 0...1.
    public let coverage: Double
    /// Share of the bucket spent moving, when the worker measured it.
    public let motion: Double?
    /// Per-bucket placement evidence (G4), when the server published it. UNKNOWN is first-class;
    /// nil means the server predates the field and readers should fall back to local derivation.
    public let placement: PlacementEligibility?
    /// Per-bucket wear evidence (G3), when the server published it. nil = no server field.
    public let wear: WearEligibility?
    /// True when placement or wear changes within the window — a mixed window has no stable label.
    /// nil = no server field.
    public let mixed: Bool?

    public init(start: Int, value: Double, samples: Int, coverage: Double, motion: Double?,
                placement: PlacementEligibility? = nil, wear: WearEligibility? = nil,
                mixed: Bool? = nil) {
        self.start = start; self.value = value; self.samples = samples
        self.coverage = coverage; self.motion = motion
        self.placement = placement; self.wear = wear; self.mixed = mixed
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
}

// MARK: - Per-window wear/placement eligibility (G4)

/// Manual placement evidence for one window (G4). `unknown` is first-class: unannotated windows are
/// UNKNOWN, never a guessed stable label.
public enum PlacementEligibility: String, Codable, Equatable, Sendable {
    case wrist
    case bicep
    case other
    case unknown

    public init?(raw: String) {
        self.init(rawValue: raw)
    }
}

/// Wear-state evidence for one window (G3). `unknown` is first-class: a window with no WRIST
/// evidence is UNKNOWN, never assumed worn. Raw values match the shared HART `WearState` wire
/// vocabulary (`on_wrist`/`off_wrist`/`unknown`) so a server-published bucket flag parses with
/// no remapping.
public enum WearEligibility: String, Codable, Equatable, Sendable {
    case worn = "on_wrist"
    case offBody = "off_wrist"
    case unknown

    public init?(raw: String) {
        self.init(rawValue: raw)
    }
}

/// Sensor-contact state for one window (G3/F4). Only present when the source actually carries
/// standard-BLE contact transitions (generic standard-HR straps); WHOOP has no such stream, so the
/// line is omitted there rather than guessed. `unknown` = no transition covers the window.
public enum ContactEligibility: String, Codable, Equatable, Sendable {
    case good
    case poor
    case unsupported
    case unknown

    /// Maps a persisted `StandardHRContact` raw value; nil for anything unrecognised (treated as
    /// absent, so an unknown byte is never a claim about contact).
    public init?(raw: String) {
        switch raw {
        case "supported_detected": self = .good
        case "supported_not_detected": self = .poor
        case "unsupported": self = .unsupported
        default: return nil
        }
    }
}

/// The derived per-window eligibility flags. A MIXED window carries `.unknown` for the changing
/// dimension rather than a guessed stable label; the per-dimension `*Mixed` flags let a consumer
/// say exactly which dimension changed (audit-g34-g7-context F3: an un-evidenced leading/trailing
/// sub-portion inside the window is itself a change — UNKNOWN mixed with a known state).
public struct IntradayEligibility: Equatable, Sendable {
    public let placement: PlacementEligibility
    public let wear: WearEligibility
    /// `placementMixed || wearMixed` (kept for wire/reader compatibility).
    public let mixed: Bool
    /// True when placement evidence changes (or starts/stops) inside the window.
    public let placementMixed: Bool
    /// True when wear evidence changes (or starts/stops) inside the window.
    public let wearMixed: Bool

    public init(placement: PlacementEligibility, wear: WearEligibility, mixed: Bool,
                placementMixed: Bool, wearMixed: Bool) {
        self.placement = placement; self.wear = wear; self.mixed = mixed
        self.placementMixed = placementMixed; self.wearMixed = wearMixed
    }

    /// Derive the flags for one half-open `[windowStart, windowEnd)` window from local evidence:
    /// placement intervals (half-open, nil end = open) and raw WRIST event rows
    /// (`(ts, kind)` with "WRIST_ON(n)"/"WRIST_OFF(n)" kinds). Pure and deterministic; gaps are
    /// UNKNOWN. When more than one placement value (or wear state) overlaps the window, or when the
    /// evidence only partially covers the window (an un-evidenced leading/trailing sub-portion), the
    /// window is MIXED and the changing dimension is `.unknown` — no stable label is assigned.
    public static func flag(windowStart: Date, windowEnd: Date,
                            placementIntervals: [PlacementInterval],
                            wearEvents: [(ts: Int, kind: String)]) -> IntradayEligibility {
        let windowStartSec = Int(windowStart.timeIntervalSince1970)
        let windowEndSec = Int(windowEnd.timeIntervalSince1970)
        let overlapping = placementIntervals
            .filter { $0.overlaps(windowStart: windowStart, windowEnd: windowEnd) }

        // Placement: unknown when nothing covers; mixed when the evidence changes OR only partially
        // covers the window (a gap inside the window is an UNKNOWN transition).
        let placementSet = Set(overlapping.map(\.placement))
        let placementCoverageComplete = coverageComplete(
            spans: overlapping.sorted { $0.effectiveStart < $1.effectiveStart }
                .map { ($0.effectiveStart, $0.effectiveEnd) },
            from: windowStartSec, to: windowEndSec)
        let placement: PlacementEligibility
        let placementMixed: Bool
        if overlapping.isEmpty {
            placement = .unknown
            placementMixed = false
        } else if placementCoverageComplete, placementSet.count == 1 {
            placement = PlacementEligibility(raw: placementSet.first!.rawValue) ?? .unknown
            placementMixed = false
        } else {
            placement = .unknown
            placementMixed = true
        }

        // Wear: spans from WRIST events (contiguous from the first span to `to` by construction);
        // the only possible gap is a leading un-evidenced portion.
        let spans = WearStateSpans.reconstruct(
            events: wearEvents, from: windowStartSec, to: windowEndSec)
        let wearStates = Set(spans.map(\.state))
        let wearCoverageComplete = spans.first?.start == windowStartSec
        let wear: WearEligibility
        let wearMixed: Bool
        if spans.isEmpty {
            wear = .unknown
            wearMixed = false
        } else if wearCoverageComplete, wearStates.count == 1 {
            wear = wearStates.first == .on ? .worn : .offBody
            wearMixed = false
        } else {
            wear = .unknown
            wearMixed = true
        }
        return IntradayEligibility(placement: placement, wear: wear,
                                   mixed: placementMixed || wearMixed,
                                   placementMixed: placementMixed, wearMixed: wearMixed)
    }

    /// Whether a set of half-open spans (sorted by start, nil end = open) covers `[from, to)` with
    /// no gap. Empty spans cover nothing; overlapping/contiguous spans merge.
    private static func coverageComplete(spans: [(start: Date, end: Date?)],
                                         from: Int, to: Int) -> Bool {
        var cursor = from
        for span in spans {
            let s = max(Int(span.start.timeIntervalSince1970), cursor)
            if s > cursor { return false }             // a gap before this span
            let e = span.end.map { Int($0.timeIntervalSince1970) } ?? to
            if e <= cursor { continue }                // fully inside what we already covered
            cursor = e
            if cursor >= to { return true }
        }
        return cursor >= to
    }
}

/// A per-metric context line set for a metric's visible window (G3/G4/G7 consumer surface). Each
/// line is per-metric and honest — never a guessed whole-window label. Absent dimensions are nil.
public struct IntradaySeriesContext: Equatable, Sendable {
    public let placementLine: String?
    public let wearLine: String?
    public let contactLine: String?

    public init(placementLine: String?, wearLine: String?, contactLine: String?) {
        self.placementLine = placementLine
        self.wearLine = wearLine
        self.contactLine = contactLine
    }

    public var hasAny: Bool { placementLine != nil || wearLine != nil || contactLine != nil }
    public var lines: [String] { [placementLine, wearLine, contactLine].compactMap { $0 } }
}

/// Builds the honest per-metric context for a window's points from server-published point flags
/// (when present) and/or local derivation, plus persisted sensor-contact transitions. Pure and
/// deterministic so the card and tests share one aggregation.
public enum IntradaySeriesContextBuilder {
    /// Summarize one metric's visible points.
    ///
    /// Honesty rules (never a guessed whole-window label):
    /// - Per point: a server-published flag (`point.placement/wear/mixed` non-nil) wins; otherwise
    ///   placement is derived locally (per-window, F3 partial-coverage aware) and wear is derived
    ///   from RANGE-WIDE WRIST spans — an event before a bucket covers it until the next event, so
    ///   sparse events do not fabricate "unknown" for windows that ARE evidenced.
    /// - Placement: any mid-window placement change/partial coverage → "Mixed placement in this
    ///   window"; a single stable value → "Wrist"/"Bicep"/"Other"; no evidence → nil.
    /// - Wear: any mid-window wear change → "Wear changed in this window"; all points one stable
    ///   state → "Worn"/"Off body"; a mix of known and unknown points → "Wear varies" (honest);
    ///   no known state anywhere → "Wear unknown".
    /// - Contact: the last transition at-or-before the window end, when one exists → "Contact
    ///   good"/"Contact poor"/"Contact not supported"; none → nil.
    public static func summarize(points: [IntradaySeriesPoint],
                                 width: Int,
                                 placementIntervals: [PlacementInterval],
                                 wearEvents: [(ts: Int, kind: String)],
                                 contactSamples: [(ts: Int, state: ContactEligibility)]) -> IntradaySeriesContext {
        guard let first = points.first, let last = points.last else {
            return IntradaySeriesContext(placementLine: nil, wearLine: nil, contactLine: nil)
        }
        let rangeStart = first.start
        let rangeEnd = last.start + width
        // Range-wide wear spans: an event before a bucket covers it until the next opposite event.
        let wearSpans = WearStateSpans.reconstruct(events: wearEvents, from: rangeStart, to: rangeEnd)

        var placementMixed = false
        var placements = Set<PlacementEligibility>()
        var wearMixed = false
        var wears = Set<WearEligibility>()
        var unknownWearPoints = false

        for point in points {
            let s = point.start
            let e = point.start + width

            // Placement dimension.
            if let published = point.placement {
                placements.insert(published)
                if point.mixed == true { placementMixed = true }
            } else {
                let local = IntradayEligibility.flag(
                    windowStart: Date(timeIntervalSince1970: TimeInterval(s)),
                    windowEnd: Date(timeIntervalSince1970: TimeInterval(e)),
                    placementIntervals: placementIntervals,
                    wearEvents: [])
                if local.placement != .unknown { placements.insert(local.placement) }
                if local.placementMixed { placementMixed = true }
            }

            // Wear dimension.
            if let published = point.wear {
                if published != .unknown { wears.insert(published) } else { unknownWearPoints = true }
                if point.mixed == true { wearMixed = true }
            } else {
                switch wearState(at: s, to: e, spans: wearSpans) {
                case .worn: wears.insert(.worn)
                case .offBody: wears.insert(.offBody)
                case .mixed: wearMixed = true
                case .unknown: unknownWearPoints = true
                }
            }
        }

        let placementLine: String?
        if placementMixed {
            placementLine = String(localized: "Mixed placement in this window")
        } else if placements.count == 1 {
            placementLine = displayPlacement(placements.first!)
        } else {
            placementLine = nil
        }

        let wearLine: String?
        if wearMixed {
            wearLine = String(localized: "Wear changed in this window")
        } else if wears.count == 1, !unknownWearPoints {
            wearLine = displayWear(wears.first!)
        } else if !wears.isEmpty {
            wearLine = String(localized: "Wear varies")
        } else {
            wearLine = String(localized: "Wear unknown")
        }

        let contactLine = contactLine(contactSamples: contactSamples, windowEnd: rangeEnd)

        return IntradaySeriesContext(placementLine: placementLine, wearLine: wearLine, contactLine: contactLine)
    }

    /// The wear state of one bucket against the range-wide contiguous spans. `.unknown` when no
    /// span covers the bucket (a gap before the first event); `.mixed` when a span boundary or a
    /// leading gap falls INSIDE the bucket (F3 — the bucket is not a stable whole-window state).
    private enum BucketWear {
        case worn
        case offBody
        case mixed
        case unknown
    }

    private static func wearState(at s: Int, to e: Int,
                                  spans: [WearStateSpans.Span]) -> BucketWear {
        let covering = spans.filter { $0.start < e && $0.end > s }
        guard let firstSpan = covering.first, let lastSpan = covering.last else { return .unknown }
        if firstSpan.start > s || lastSpan.end < e {
            // A leading gap or a trailing transition inside the bucket: not a stable state.
            return .mixed
        }
        let states = Set(covering.map(\.state))
        guard states.count == 1 else { return .mixed }
        return states.first == .on ? .worn : .offBody
    }

    private static func displayPlacement(_ p: PlacementEligibility) -> String {
        switch p {
        case .wrist: return String(localized: "Wrist")
        case .bicep: return String(localized: "Bicep")
        case .other: return String(localized: "Other")
        case .unknown: return String(localized: "Placement unknown")
        }
    }

    private static func displayWear(_ w: WearEligibility) -> String {
        switch w {
        case .worn: return String(localized: "Worn")
        case .offBody: return String(localized: "Off body")
        case .unknown: return String(localized: "Wear unknown")
        }
    }

    /// The last contact transition at-or-before `windowEnd` (contact is a state with transitions;
    /// the most recent one defines the effective state). Nil when none covers the window.
    private static func contactLine(contactSamples: [(ts: Int, state: ContactEligibility)],
                                    windowEnd: Int) -> String? {
        let effective = contactSamples
            .filter { $0.ts <= windowEnd && $0.state != .unknown }
            .sorted { $0.ts < $1.ts }
            .last
        guard let effective else { return nil }
        switch effective.state {
        case .good: return String(localized: "Contact good")
        case .poor: return String(localized: "Contact poor")
        case .unsupported: return String(localized: "Contact not supported")
        case .unknown: return nil
        }
    }
}


/// A running total at an instant.
public struct IntradayCumulativePoint: Equatable, Sendable {
    public let ts: Int
    public let total: Double
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

/// What `GET scores/series` returns for one range: the buckets the worker has published, per metric.
///
/// An absent bucket is an absent bucket, never a zero: a metric the worker could not measure for a
/// stretch (wrist moving, strap off, phone not synced) simply has no point there.
public struct IntradaySeriesWindow: Equatable, Sendable {
    public let from: Int
    public let to: Int
    /// The widest bucket in the range: the width of any metric that does not name its own.
    public let bucketSeconds: Int
    /// Each metric's own bucket width. Respiratory rate, steps and calories are one-minute buckets while HRV
    /// and resting heart rate are five-minute ones; a server that predates per-metric widths sends none, and
    /// every metric then uses `bucketSeconds`.
    public let metricBucketSeconds: [IntradayMetric: Int]
    /// When the server last wrote any bucket in this range.
    public let latestComputedAt: Date?
    public let metrics: [IntradayMetric: [IntradaySeriesPoint]]

    public init(from: Int, to: Int, bucketSeconds: Int = 300, metricBucketSeconds: [IntradayMetric: Int] = [:],
                latestComputedAt: Date? = nil, metrics: [IntradayMetric: [IntradaySeriesPoint]]) {
        self.from = from; self.to = to; self.bucketSeconds = bucketSeconds
        self.metricBucketSeconds = metricBucketSeconds
        self.latestComputedAt = latestComputedAt; self.metrics = metrics
    }

    /// How wide one of this metric's buckets is, in seconds.
    public func bucketSeconds(for metric: IntradayMetric) -> Int {
        metricBucketSeconds[metric] ?? bucketSeconds
    }

    /// Parse the edge response, `{ "series": { from, to, bucket_seconds, latest_computed_at, metrics }, … }`,
    /// or the inner `series` object on its own (which is what the cache stores).
    ///
    /// Rows that are not `[ts, value, samples, coverage, motion?]` with finite numbers are dropped, rows
    /// are sorted by time, and a repeated timestamp keeps its last value, so a damaged row can cost one
    /// point and never the screen.
    public init?(envelope: [String: Any]) {
        let object = (envelope["series"] as? [String: Any]) ?? envelope
        guard let from = (object["from"] as? NSNumber)?.intValue,
              let to = (object["to"] as? NSNumber)?.intValue, to > from,
              let raw = object["metrics"] as? [String: Any] else { return nil }
        let bucket = (object["bucket_seconds"] as? NSNumber)?.intValue ?? 300
        var widths: [IntradayMetric: Int] = [:]
        if let named = object["metric_bucket_seconds"] as? [String: Any] {
            for metric in IntradayMetric.allCases {
                if let width = (named[metric.rawValue] as? NSNumber)?.intValue, width > 0 { widths[metric] = width }
            }
        }

        var parsed: [IntradayMetric: [IntradaySeriesPoint]] = [:]
        for metric in IntradayMetric.allCases {
            guard let rows = raw[metric.rawValue] as? [[Any]] else { continue }
            var byStart: [Int: IntradaySeriesPoint] = [:]
            for row in rows where row.count >= 4 {
                guard let start = (row[0] as? NSNumber)?.intValue, start > 0,
                      let value = (row[1] as? NSNumber)?.doubleValue, value.isFinite,
                      let samples = (row[2] as? NSNumber)?.intValue,
                      let coverage = (row[3] as? NSNumber)?.doubleValue, coverage.isFinite else { continue }
                let motion = row.count > 4 ? (row[4] as? NSNumber)?.doubleValue : nil
                // Additive G4/G3 flags: rows 5..7 are optional; a server that predates them sends
                // none and existing readers simply ignore the absent fields.
                let placement = row.count > 5 ? (row[5] as? String).flatMap(PlacementEligibility.init(raw:)) : nil
                let wear = row.count > 6 ? (row[6] as? String).flatMap(WearEligibility.init(raw:)) : nil
                let mixed = row.count > 7 ? (row[7] as? NSNumber)?.boolValue : nil
                byStart[start] = IntradaySeriesPoint(start: start, value: value, samples: samples,
                                                     coverage: coverage,
                                                     motion: motion.flatMap { $0.isFinite ? $0 : nil },
                                                     placement: placement, wear: wear, mixed: mixed)
            }
            parsed[metric] = byStart.values.sorted { $0.start < $1.start }
        }
        self.init(from: from, to: to, bucketSeconds: bucket > 0 ? bucket : 300, metricBucketSeconds: widths,
                  latestComputedAt: (object["latest_computed_at"] as? String).flatMap(Self.parseTimestamp),
                  metrics: parsed)
    }

    public func points(_ metric: IntradayMetric) -> [IntradaySeriesPoint] { metrics[metric] ?? [] }

    public func latest(_ metric: IntradayMetric) -> IntradaySeriesPoint? { points(metric).last }

    public var isEmpty: Bool { metrics.values.allSatisfy(\.isEmpty) }

    /// The sum of every bucket: for steps and calories, the day's total so far.
    public func total(_ metric: IntradayMetric) -> Double { points(metric).reduce(0) { $0 + $1.value } }

    /// Running totals for an additive metric, each stamped where its bucket ends.
    public func cumulative(_ metric: IntradayMetric) -> [IntradayCumulativePoint] {
        var running = 0.0
        let width = bucketSeconds(for: metric)
        return points(metric).map { point in
            running += point.value
            return IntradayCumulativePoint(ts: point.start + width, total: running)
        }
    }

    /// The running total as a staircase for drawing: each bucket contributes the total just before it
    /// (at its start) and just after it (at its end). Joining the ends alone would slope across a stretch
    /// with no buckets, as if steps had been taken there; this holds the total flat until the next bucket.
    public func staircase(_ metric: IntradayMetric) -> [IntradayCumulativePoint] {
        var running = 0.0
        var out: [IntradayCumulativePoint] = []
        let width = bucketSeconds(for: metric)
        for point in points(metric) {
            out.append(IntradayCumulativePoint(ts: point.start, total: running))
            running += point.value
            out.append(IntradayCumulativePoint(ts: point.start + width, total: running))
        }
        return out
    }

    /// Consecutive buckets as lines. A hole longer than `maxGapBuckets` buckets (and never shorter than
    /// `minGapSeconds`, so a one-minute metric is not cut by every short dropout) ends a line, so a stretch
    /// with no reading shows as a gap and never as a straight segment drawn across it.
    public func runs(_ metric: IntradayMetric, maxGapBuckets: Int = 3,
                     minGapSeconds: Int = 300) -> [[IntradaySeriesPoint]] {
        var grouped: [[IntradaySeriesPoint]] = []
        let limit = max(maxGapBuckets * bucketSeconds(for: metric), minGapSeconds)
        for point in points(metric) {
            if let previous = grouped.last?.last, point.start - previous.start <= limit {
                grouped[grouped.count - 1].append(point)
            } else {
                grouped.append([point])
            }
        }
        return grouped
    }

    /// Postgres writes `timestamptz` with microseconds and a `+00:00` offset; `ISO8601DateFormatter`
    /// reads at most milliseconds, so the fraction is cut to three digits first.
    static func parseTimestamp(_ text: String) -> Date? {
        var normalized = text
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, ("0"..."9").contains(text[end]) { end = text.index(after: end) }
            let digits = String(text[text.index(after: dot)..<end].prefix(3))
            normalized = String(text[..<dot]) + "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0)
                + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }
}

/// Which stretch of time a screen asks the server for.
public enum IntradayRange {
    public static let bucketSeconds = 300
    public static let maxDayOffset = 6

    public struct Bounds: Equatable, Sendable {
        public let from: Int
        public let to: Int
        /// A stable cache name: the same screen asking again finds the same entry.
        public let key: String
        /// The window still grows as data arrives, so it is worth re-reading on a timer.
        public let isLive: Bool
    }

    /// `dayOffset` 0 is "now": for a line metric the last 24 hours (so a night that straddles midnight is
    /// one unbroken picture), for an additive metric the local calendar day so far (so the running total
    /// lands on the day's number). 1...6 are whole local calendar days, that many days back.
    public static func bounds(for metric: IntradayMetric, dayOffset: Int, now: Date,
                              calendar: Calendar = .current) -> Bounds {
        let offset = min(max(dayOffset, 0), maxDayOffset)
        if offset == 0, !metric.isCumulative {
            // To the end of the current bucket, so the newest bucket is always inside the window.
            let to = (Int(now.timeIntervalSince1970) / bucketSeconds + 1) * bucketSeconds
            return Bounds(from: to - 86_400, to: to, key: "\(metric.rawValue)|live", isLive: true)
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -offset, to: today)
            ?? today.addingTimeInterval(-Double(offset) * 86_400)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let from = Int(start.timeIntervalSince1970)
        return Bounds(from: from, to: Int(end.timeIntervalSince1970),
                      key: "\(metric.rawValue)|day|\(from)", isLive: offset == 0)
    }
}

/// How the daily-history chart on a metric page counts itself.
///
/// For the five metrics the worker computes through the day, that chart still plots ONE summary per day,
/// so calling its points "readings" and flagging a short history as "sparse" told the reader the metric is
/// recorded a couple of times in total, while the card above it shows hundreds. These count days and say
/// so, and a widened window is described as what it is rather than as a data problem.
public enum DailyHistoryWording {
    public static func caption(days: Int, rangeName: String, widened: Bool) -> String {
        let span = widened ? String(localized: "showing \(rangeName)") : rangeName
        return days == 1
            ? String(localized: "1 day · \(span)")
            : String(localized: "\(days) days · \(span)")
    }

    public static func rangeName(_ rangeName: String, widened: Bool) -> String {
        widened ? String(localized: "showing \(rangeName)") : rangeName
    }
}

public enum IntradayFormat {
    /// "just now", "12 min ago", "3 h ago". A time in the future (a skewed clock) reads as "just now"
    /// and never claims freshness it cannot back.
    public static func age(from past: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(past))
        if seconds < 90 { return String(localized: "just now") }
        if seconds < 3_600 { return String(localized: "\(seconds / 60) min ago") }
        if seconds < 86_400 { return String(localized: "\(seconds / 3_600) h ago") }
        return String(localized: "\(seconds / 86_400) d ago")
    }
}
