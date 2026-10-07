import Foundation

// KeyMetricDetailModel.swift — which metrics open the simplified key-metric screen (`KeyMetricDetailView`: the
// latest measured value, one history chart, the server's explanation), and the pure rules behind that screen.
// Every other metric keeps `MetricDetailView`'s full dossier.

// MARK: - Catalog

/// The metric drill-downs that are the simplified key-metric screen, and the server metric that explains each.
///
/// `MetricDetailView.body` consults `entry(for:)` first, so every entry point that pushes a metric detail (the
/// Explore list, Today's tiles and cards, Trends, Sleep, Health, `TabRoute`) reaches the same screen.
enum KeyMetricCatalog {

    /// Flip to `true` to give Heart Rate Variability the simplified screen as well. The server already explains
    /// `hrv_rmssd`; HRV keeps the full dossier (with its RMSSD + SDNN chart) until that is signed off.
    static let hrvEnabled = false

    struct Entry: Equatable, Sendable {
        /// `MetricDescriptor.key`.
        let catalogKey: String
        /// `MetricDescriptor.source`. The server explains the strap's own nights (`server_daily_scores`), so only
        /// the strap's descriptor is routed: another source's resting HR (a Mi Band import) is different data.
        let source: String
        let insightMetric: MetricInsightMetric
        let enabled: Bool
    }

    static let entries: [Entry] = [
        Entry(catalogKey: "rhr", source: "my-whoop", insightMetric: .restingHeartRate, enabled: true),
        Entry(catalogKey: "hrv", source: "my-whoop", insightMetric: .hrvRmssd, enabled: hrvEnabled),
    ]

    /// The routing entry for `metric`, nil when it keeps the full dossier.
    static func entry(for metric: MetricDescriptor) -> Entry? {
        entries.first { $0.enabled && $0.catalogKey == metric.key && $0.source == metric.source }
    }
}

// MARK: - History

/// The measured nights behind the screen and the chart's windowing and gap rules. Day keys are `yyyy-MM-dd`
/// calendar days handled in UTC, like every other day-keyed chart in the app.
enum KeyMetricHistory {

    /// One measured night.
    struct Night: Equatable, Identifiable, Sendable {
        /// `yyyy-MM-dd`.
        let day: String
        /// The day at 00:00 UTC (the chart's x position).
        let date: Date
        let value: Double
        var id: String { day }
    }

    /// The range chips, shortest first.
    static let ranges: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
    static let defaultRange: ExploreRange = .month

    private static var calendar: Calendar { PhysiologyContextDates.calendar }

    /// The measured nights of a local series, ascending, one per day. A night with no reading is simply absent. A
    /// non-finite, zero or negative value is a placeholder, not a measurement, so it is dropped too: a missing
    /// night must read as missing, never as zero.
    static func measuredNights(_ series: [(day: String, value: Double)]) -> [Night] {
        var byDay: [String: Night] = [:]
        for row in series where row.value.isFinite && row.value > 0 {
            guard byDay[row.day] == nil, let date = PhysiologyContextDates.date(row.day) else { continue }
            byDay[row.day] = Night(day: row.day, date: date, value: row.value)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The headline: the latest measured night, nil when nothing has been measured.
    static func latestMeasured(_ series: [(day: String, value: Double)]) -> Night? {
        measuredNights(series).last
    }

    /// The calendar days a range shows: the trailing `range.days` days ending at the latest measured night (so a
    /// stale-but-present history still draws), or first through last measured night for ALL. A single-night ALL
    /// still spans a week so the chart has an axis to sit on. Nil when nothing has been measured.
    static func domain(_ nights: [Night], range: ExploreRange) -> ClosedRange<Date>? {
        guard let first = nights.first, let last = nights.last else { return nil }
        if let days = range.days, days > 0 {
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: last.date) ?? last.date
            return start...last.date
        }
        guard first.date < last.date else {
            return (calendar.date(byAdding: .day, value: -6, to: last.date) ?? last.date)...last.date
        }
        return first.date...last.date
    }

    /// The measured nights inside `domain`.
    static func window(_ nights: [Night], domain: ClosedRange<Date>?) -> [Night] {
        guard let domain else { return [] }
        return nights.filter { domain.contains($0.date) }
    }

    /// Calendar days in `domain`, inclusive.
    static func dayCount(_ domain: ClosedRange<Date>) -> Int {
        (calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 0) + 1
    }

    /// Runs of consecutive measured nights. A run breaks wherever one or more calendar nights between two measured
    /// nights have no reading, so the line never bridges a night that was not measured (and never dips to zero).
    static func runs(_ nights: [Night]) -> [[Night]] {
        var runs: [[Night]] = []
        for night in nights {
            if let previous = runs.last?.last,
               calendar.dateComponents([.day], from: previous.date, to: night.date).day == 1 {
                runs[runs.count - 1].append(night)
            } else {
                runs.append([night])
            }
        }
        return runs
    }

    /// Whole days between the first and last measured night (0 for one night or none).
    static func spanDays(_ nights: [Night]) -> Int {
        guard let first = nights.first, let last = nights.last else { return 0 }
        return calendar.dateComponents([.day], from: first.date, to: last.date).day ?? 0
    }

    /// Whether a range chip is selectable (the #943 rule the full dossier uses): a longer range unlocks only once
    /// the history would show more than the chip below it, so thin history cannot be stretched under a 1Y label.
    /// W and ALL never lock, and with no history nothing locks.
    static func isUnlocked(_ range: ExploreRange, spanDays: Int, hasHistory: Bool) -> Bool {
        guard ranges.contains(range) else { return false }
        guard hasHistory else { return true }
        switch range {
        case .week, .all: return true
        case .month:      return spanDays > ExploreRange.week.rawValue
        case .quarter:    return spanDays > ExploreRange.month.rawValue
        case .half:       return spanDays > ExploreRange.quarter.rawValue
        case .year:       return spanDays > ExploreRange.half.rawValue
        case .twoWeeks, .threeWeeks: return false
        }
    }

    /// The chart's y range: the window's own values with a little air (at least `minimumPad` either side), so a
    /// flat week still has height. Never pinned to zero: zero is not a reading.
    static func valueDomain(_ values: [Double], minimumPad: Double = 3) -> ClosedRange<Double>? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let pad = max((hi - lo) * 0.15, minimumPad)
        return max(0, lo - pad)...(hi + pad)
    }

    /// `metric.format`'s text split into the number and its unit, so the headline can set the unit smaller. When
    /// the text does not end in the unit it is returned whole.
    static func splitUnit(_ formatted: String, unit: String) -> (number: String, unit: String?) {
        let suffix = " " + unit
        guard !unit.isEmpty, formatted.hasSuffix(suffix), formatted.count > suffix.count else { return (formatted, nil) }
        return (String(formatted.dropLast(suffix.count)), unit)
    }
}

// MARK: - Dates

/// Day labels for the key-metric screen, formatted in UTC (day keys are calendar days; a local zone west of UTC
/// would otherwise print the previous day) with the app language's words.
enum KeyMetricDates {
    static func format(_ date: Date, template: String, locale: Locale = AppLanguage.activeLocale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// "Tue, 6 Oct 2026".
    static func night(_ date: Date) -> String { format(date, template: "EEEdMMMyyyy") }

    /// "Tue, 6 Oct", with the year when asked.
    static func shortNight(_ date: Date, includeYear: Bool) -> String {
        format(date, template: includeYear ? "EEEdMMMyyyy" : "EEEdMMM")
    }

    /// "6 Oct 2026" for a `yyyy-MM-dd` key; nil when it is not one.
    static func day(_ key: String, locale: Locale = AppLanguage.activeLocale) -> String? {
        PhysiologyContextDates.date(key).map { format($0, template: "dMMMyyyy", locale: locale) }
    }
}
