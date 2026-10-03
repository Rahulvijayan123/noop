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

    public init(start: Int, value: Double, samples: Int, coverage: Double, motion: Double?) {
        self.start = start; self.value = value; self.samples = samples
        self.coverage = coverage; self.motion = motion
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
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
                byStart[start] = IntradaySeriesPoint(start: start, value: value, samples: samples,
                                                     coverage: coverage,
                                                     motion: motion.flatMap { $0.isFinite ? $0 : nil })
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
