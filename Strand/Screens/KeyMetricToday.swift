import Foundation
import StrandAnalytics

// KeyMetricToday.swift — what the key-metric screen opens on: today's value against the person's own recent
// baselines (the median of the 7, 30 and 90 periods before it). Pure, so the rules (which day counts as "today",
// which baselines have enough readings) are tested without a view. The history charts stay one tap away.

struct KeyMetricToday: Equatable {
    /// One baseline: the median of the readings in the `days` before the reference day, and how far the value sits
    /// from it.
    struct Baseline: Equatable, Identifiable {
        let days: Int
        let median: Double
        let count: Int
        /// The value minus the median, in the metric's own unit.
        let delta: Double
        var id: Int { days }
    }

    enum Freshness: Equatable {
        /// The reading belongs to today: a night keyed by the day it ends, or a day metric so far.
        case today
        /// Nothing yet today; `value` is the newest earlier reading, from this `yyyy-MM-dd` day.
        case earlier(String)
        /// Nothing measured at all.
        case none
    }

    let value: Double?
    /// The day `value` belongs to, nil when there is none.
    let day: String?
    let freshness: Freshness
    let baselines: [Baseline]

    /// The windows compared against, in days (nights for a night metric).
    static let windows = [7, 30, 90]
    /// A baseline needs this many readings before it is a comparison and not a guess.
    static let minimumReadings = 3

    /// - Parameters:
    ///   - readings: every measured night or day, ascending (a day metric's today is not in it).
    ///   - todayValue: a day metric's value so far today (steps, calories); nil for a night metric, whose today is
    ///     last night and is already in `readings`.
    ///   - today: the local `yyyy-MM-dd`.
    static func make(readings: [KeyMetricHistory.Reading], todayValue: Double?, today: String) -> KeyMetricToday {
        let value: Double
        let day: String
        let freshness: Freshness
        if let todayValue, todayValue.isFinite {
            value = todayValue
            day = today
            freshness = .today
        } else if let last = readings.last {
            value = last.value
            day = last.day
            freshness = last.day >= today ? .today : .earlier(last.day)
        } else {
            return KeyMetricToday(value: nil, day: nil, freshness: .none, baselines: [])
        }
        let baselines: [Baseline] = windows.compactMap { span in
            guard let cutoff = PhysiologyContextDates.key(day, minusDays: span) else { return nil }
            // The `span` periods just before the reference day (the day itself is what is being compared).
            let prior = readings.filter { $0.day >= cutoff && $0.day < day }.map(\.value)
            guard prior.count >= minimumReadings, let median = KeyMetricSummary.median(prior) else { return nil }
            return Baseline(days: span, median: median, count: prior.count, delta: value - median)
        }
        return KeyMetricToday(value: value, day: day, freshness: freshness, baselines: baselines)
    }
}

enum KeyMetricTodayCopy {
    static var today: String { String(localized: "Today") }
    static var history: String { String(localized: "History") }

    /// The line under the number.
    static func caption(_ freshness: KeyMetricToday.Freshness, period: MetricInsightPeriod, earlier: String?) -> String {
        switch freshness {
        case .today:
            return period == .night ? String(localized: "Today, from last night") : String(localized: "Today so far")
        case .earlier:
            let when = earlier ?? ""
            return period == .night ? String(localized: "No reading yet today. Latest: \(when)")
                : String(localized: "Nothing recorded yet today. Latest full day: \(when)")
        case .none:
            return String(localized: "Nothing measured yet")
        }
    }

    static var compareTitle: String { String(localized: "Compared with your own baselines") }

    /// "Last 7 nights", "Last 30 days".
    static func baselineTitle(days: Int, period: MetricInsightPeriod) -> String {
        period == .night ? String(localized: "Last \(days) nights") : String(localized: "Last \(days) days")
    }

    /// "Median 52 bpm from 28 nights".
    static func baselineDetail(median: String, count: Int, period: MetricInsightPeriod) -> String {
        period == .night ? String(localized: "Median \(median) from \(count) nights")
            : String(localized: "Median \(median) from \(count) days")
    }

    static var noBaselines: String {
        String(localized: "Baselines appear after three nights or days of readings.")
    }

    static var sameAsBaseline: String { String(localized: "No difference") }
    static var seeHistory: String { String(localized: "See the history") }
    static var usualRange: String { String(localized: "Your usual range") }
    static var recentRange: String { String(localized: "Your recent range") }

    /// A signed difference: "+3 bpm", "−2 ms".
    static func delta(_ text: String, positive: Bool) -> String { (positive ? "+" : "\u{2212}") + text }
}
