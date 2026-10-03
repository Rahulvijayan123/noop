import Foundation

/// The coach's view of the server's dense intraday series: the same buckets the metric pages draw (one
/// minute for respiratory rate, steps and calories, five for HRV and resting heart rate), turned into text a
/// model can quote.
///
/// The model reads this INSTEAD of inferring what the device records from the daily rows, which carry one
/// overnight HRV per day and read as if that were all the strap produces.
enum CoachIntraday {
    /// Tool-argument spellings, mapped to the series the worker publishes.
    static func metric(named raw: String) -> IntradayMetric? {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "hrv", "hrv_rmssd_ms", "heart_rate_variability": return .hrv
        case "rhr", "resting_hr", "resting_hr_bpm", "resting_heart_rate": return .restingHeartRate
        case "respiration", "resp_rate", "resp_rate_bpm", "respiratory_rate", "breathing": return .respiratoryRate
        case "steps": return .steps
        case "calories", "calories_kcal", "active_calories", "energy": return .calories
        default: return nil
        }
    }

    static let metricNames = "hrv|rhr|respiration|steps|calories"

    static func title(_ metric: IntradayMetric) -> String {
        switch metric {
        case .hrv: return "HRV (RMSSD)"
        case .restingHeartRate: return "Resting heart rate"
        case .respiratoryRate: return "Respiratory rate"
        case .steps: return "Steps"
        case .calories: return "Calories"
        }
    }

    /// What the buckets are, said once, so the model never describes these as once-a-day values.
    static func provenance(_ metric: IntradayMetric, bucketSeconds: Int = 300) -> String {
        let base = "Computed on the server from the strap's data and recomputed about every 5 minutes as new data syncs; "
            + "each reading covers a \(bucketWording(bucketSeconds)) bucket. A time with no reading means no valid one was possible then "
            + "(strap off, phone not yet synced"
        switch metric {
        case .hrv: return base + ", or the wrist moving, since HRV is only read when the wrist is still)."
        case .restingHeartRate: return base + ", or the wrist moving)."
        case .respiratoryRate: return base + ", the wrist moving, or too few clean beats; each reading pools about the last 2 minutes of breaths)."
        case .steps, .calories: return base + "). Each value is that bucket's share of the day's total."
        }
    }

    /// "5-minute" / "1-minute" (or "90-second" for anything that is not a whole minute).
    static func bucketWording(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)-minute" : "\(seconds)-second"
    }

    static func describe(window: IntradaySeriesWindow, metric: IntradayMetric,
                         timeZone: TimeZone = .current, now: Date = Date()) -> String {
        let points = window.points(metric)
        let name = title(metric)
        let width = window.bucketSeconds(for: metric)
        let each = width % 60 == 0 ? "\(width / 60) minute\(width == 60 ? "" : "s")" : "\(width) seconds"
        let span = "\(stamp(Date(timeIntervalSince1970: TimeInterval(window.from)), timeZone)) to "
            + stamp(Date(timeIntervalSince1970: TimeInterval(window.to)), timeZone)
        guard !points.isEmpty else {
            return "\(name): no readings between \(span) (\(timeZone.identifier)). "
                + "That means no valid reading was computed for the window, not that the device only records once a day. "
                + provenance(metric, bucketSeconds: width)
        }

        var lines = ["\(name), \(span) (\(timeZone.identifier)): \(points.count) readings of \(each) each. " + provenance(metric, bucketSeconds: width)]
        let values = points.map(\.value)
        let latest = points[points.count - 1]
        let age = IntradayFormat.age(from: latest.date.addingTimeInterval(TimeInterval(width)), to: now)

        if metric.isCumulative {
            let total = values.reduce(0, +)
            lines.append("Total in window: \(metric.format(total)) \(metric.unit). Latest bucket \(clock(latest.date, timeZone)): \(metric.format(latest.value)) (ends \(age)).")
        } else {
            let mean = values.reduce(0, +) / Double(values.count)
            lines.append("Latest \(metric.format(latest.value)) \(metric.unit) at \(clock(latest.date, timeZone)) (\(age)); "
                + "min \(metric.format(values.min() ?? 0)), mean \(metric.format(mean)), max \(metric.format(values.max() ?? 0)) \(metric.unit).")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var hours: [(start: Date, values: [Double])] = []
        for point in points {
            let hour = calendar.dateInterval(of: .hour, for: point.date)?.start ?? point.date
            if let last = hours.last, last.start == hour {
                hours[hours.count - 1].values.append(point.value)
            } else {
                hours.append((hour, [point.value]))
            }
        }
        lines.append(metric.isCumulative ? "By hour (total, readings in the hour):" : "By hour (mean, readings in the hour):")
        for hour in hours {
            let sum = hour.values.reduce(0, +)
            let shown = metric.isCumulative ? sum : sum / Double(hour.values.count)
            lines.append("  \(stamp(hour.start, timeZone)): \(metric.format(shown)) (\(hour.values.count))")
        }

        let recent = points.suffix(12)
        lines.append("Most recent readings:")
        for point in recent {
            lines.append("  \(clock(point.date, timeZone)): \(metric.format(point.value))")
        }
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date, _ zone: TimeZone) -> String { format(date, zone, "EEE MMM d HH:mm") }
    private static func clock(_ date: Date, _ zone: TimeZone) -> String { format(date, zone, "HH:mm") }

    private static func format(_ date: Date, _ zone: TimeZone, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
