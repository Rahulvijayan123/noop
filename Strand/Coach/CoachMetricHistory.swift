import Foundation
import WhoopStore

/// `query_metric_history` and `find_days`: the long view over every synced day (up to 4,000), read on the phone
/// so a year of HRV never has to leave it. Both answer with a capped, plain-text table the model can quote: a
/// header with the metric, unit, window, the number of days measured and the coverage, then rows newest first.
/// A dash means not measured, never zero.
enum CoachMetricHistory {
    static let maxRows = 120
    static let maxDays = 4_000
    static let defaultDays = 365
    static let defaultFindLimit = 10
    static let maxFindLimit = 30

    enum Group: String, CaseIterable, Sendable {
        case day, week, month, year

        var coarser: Group? {
            switch self {
            case .day: return .week
            case .week: return .month
            case .month: return .year
            case .year: return nil
            }
        }

        var adjective: String {
            switch self {
            case .day: return "daily"
            case .week: return "weekly"
            case .month: return "monthly"
            case .year: return "yearly"
            }
        }
    }

    enum Stat: String, CaseIterable, Sendable { case mean, min, max, sum }
    enum Order: String, CaseIterable, Sendable { case recent, lowest, highest }

    /// The `CoachChartMetric` names, plus the everyday words a model reaches for.
    static func metric(named raw: String?) -> CoachChartMetric? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let exact = CoachChartMetric(rawValue: raw) { return exact }
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        if let match = CoachChartMetric.allCases.first(where: { $0.rawValue.lowercased() == key }) { return match }
        switch key {
        case "recovery", "readiness": return .charge
        case "strain", "load": return .effort
        case "sleep", "sleepduration", "sleephrs", "totalsleep": return .sleepHours
        case "heartratevariability", "rmssd": return .hrv
        case "restinghr", "restingheartrate", "restingheart", "resting": return .rhr
        case "bloodoxygen", "oxygen", "spo2pct": return .spo2
        case "respiratoryrate", "resp", "breathing": return .respiration
        case "skintemperature", "temperature", "temp", "skintempdev": return .skinTemp
        case "step": return .steps
        case "calories", "activecalorie", "kcal", "energy": return .activeCalories
        default: return nil
        }
    }

    static var metricNames: String { CoachChartMetric.allCases.map(\.rawValue).joined(separator: "|") }

    // MARK: query_metric_history

    /// One metric grouped by `group` (coarsened automatically past 120 rows) and summarised with `stat`, over
    /// `from`…`to` or the `days` ending today.
    static func history(days rows: [DailyMetric], metric: CoachChartMetric, from: String? = nil, to: String? = nil,
                        days: Int? = nil, group: Group = .month, stat: Stat = .mean,
                        now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let span = window(from: from, to: to, days: days ?? defaultDays, now: now, timeZone: timeZone)
        let inRange = values(rows, metric: metric, from: span.from, to: span.to)
        let label = "\(metric.title) (\(metric.unit))"
        guard !inRange.isEmpty else {
            return "No \(metric.title) recorded between \(span.from) and \(span.to)." + coverageHint(rows, metric: metric)
        }

        var grouping = group
        while groupCount(from: span.from, to: span.to, group: grouping) > maxRows, let next = grouping.coarser {
            grouping = next
        }
        let calendarDays = dayCount(from: span.from, to: span.to)
        let pct = calendarDays > 0 ? Int((Double(inRange.count) / Double(calendarDays) * 100).rounded()) : 0
        var lines = ["LONG-TERM HISTORY: \(label), \(grouping.adjective) \(stat.rawValue), \(span.from) to \(span.to) "
            + "(\(calendarDays) days): measured on \(inRange.count) days (\(pct)% coverage), first \(inRange.first!.day), "
            + "last \(inRange.last!.day)."]
        if grouping != group {
            lines.append("Grouped by \(grouping.rawValue) because a \(group.rawValue) table would pass \(maxRows) rows.")
        }

        let all = inRange.map(\.value)
        let lowest = inRange.min { $0.value < $1.value }!, highest = inRange.max { $0.value < $1.value }!
        var whole = "Whole window: mean \(format(all.reduce(0, +) / Double(all.count), metric)), "
            + "min \(format(lowest.value, metric)) (\(lowest.day)), max \(format(highest.value, metric)) (\(highest.day))"
        if stat == .sum { whole += ", total \(format(all.reduce(0, +), metric))" }
        lines.append(whole + ".")
        lines.append("Newest first; a dash means not measured:")

        var buckets: [String: [Double]] = [:]
        for item in inRange { buckets[key(for: item.day, group: grouping), default: []].append(item.value) }
        for bucket in groupKeys(from: span.from, to: span.to, group: grouping).reversed().prefix(maxRows) {
            guard let xs = buckets[bucket], !xs.isEmpty else {
                lines.append("  \(bucket): —")
                continue
            }
            let value: Double
            switch stat {
            case .mean: value = xs.reduce(0, +) / Double(xs.count)
            case .min: value = xs.min()!
            case .max: value = xs.max()!
            case .sum: value = xs.reduce(0, +)
            }
            lines.append(grouping == .day ? "  \(bucket): \(format(value, metric))"
                                          : "  \(bucket): \(format(value, metric)) (\(xs.count) d)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: find_days

    /// Days whose value is below and/or above a threshold (or simply the latest measured days), ordered and
    /// capped at `limit`, each with the day's other headline numbers for context.
    static func findDays(days rows: [DailyMetric], metric: CoachChartMetric, below: Double? = nil, above: Double? = nil,
                         from: String? = nil, to: String? = nil, limit: Int? = nil, order: Order = .recent,
                         now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let span = window(from: from, to: to, days: from == nil ? maxDays : nil, now: now, timeZone: timeZone)
        let measured = values(rows, metric: metric, from: span.from, to: span.to)
        guard !measured.isEmpty else {
            return "No \(metric.title) recorded between \(span.from) and \(span.to)." + coverageHint(rows, metric: metric)
        }
        var matches = measured.filter { item in
            (below.map { item.value < $0 } ?? true) && (above.map { item.value > $0 } ?? true)
        }
        switch order {
        case .recent: matches.reverse()
        case .lowest: matches.sort { $0.value != $1.value ? $0.value < $1.value : $0.day > $1.day }
        case .highest: matches.sort { $0.value != $1.value ? $0.value > $1.value : $0.day > $1.day }
        }
        let cap = min(max(limit ?? defaultFindLimit, 1), maxFindLimit)
        let shown = Array(matches.prefix(cap))

        var condition = ""
        if let below, let above { condition = " between \(format(above, metric)) and \(format(below, metric))" }
        else if let below { condition = " below \(format(below, metric))" }
        else if let above { condition = " above \(format(above, metric))" }
        let orderText = order == .recent ? "newest first" : order == .lowest ? "lowest first" : "highest first"
        var lines = ["MATCHING DAYS: \(metric.title) (\(metric.unit))\(condition), \(span.from) to \(span.to): "
            + "\(matches.count) of \(measured.count) measured days match; showing \(shown.count), \(orderText)."]
        if matches.count > shown.count {
            lines.append("There are at least \(matches.count - shown.count) more; narrow the dates or the threshold to see them.")
        }
        guard !shown.isEmpty else {
            lines.append("No day in the window meets that condition.")
            return lines.joined(separator: "\n")
        }
        let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        for item in shown {
            var line = "  \(item.day) (\(weekday(item.day))): \(format(item.value, metric)) \(metric.unit)"
            if let day = byDay[item.day] {
                let context = contextFields(day, excluding: metric)
                if !context.isEmpty { line += " — " + context }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    struct Item: Equatable { let day: String; let value: Double }

    /// The measured, finite values in `from…to` (inclusive day keys), oldest first.
    static func values(_ rows: [DailyMetric], metric: CoachChartMetric, from: String, to: String) -> [Item] {
        rows.compactMap { d -> Item? in
            guard d.day >= from, d.day <= to, let v = metric.value(d), v.isFinite else { return nil }
            return Item(day: d.day, value: v)
        }
        .sorted { $0.day < $1.day }
    }

    /// Inclusive day keys. Without `from`, the window is the `days` ending at `to` (or today); the span is
    /// capped at 4,000 days.
    static func window(from: String?, to: String?, days: Int?, now: Date, timeZone: TimeZone) -> (from: String, to: String) {
        let today = CoachDates.day(now, timeZone: timeZone)
        let end = normalizedDay(to) ?? today
        let span = min(max(days ?? defaultDays, 1), maxDays)
        var start = normalizedDay(from) ?? shift(end, by: -(span - 1))
        if start > end { start = end }
        let earliest = shift(end, by: -(maxDays - 1))
        if start < earliest { start = earliest }
        return (start, end)
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func date(_ day: String) -> Date? { dayFormatter.date(from: day) }

    private static func string(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Accepts `yyyy-MM-dd` or a full ISO timestamp; anything else is ignored.
    private static func normalizedDay(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { return nil }
        let head = String(raw.prefix(10))
        return date(head) == nil ? nil : head
    }

    private static func shift(_ day: String, by days: Int) -> String {
        guard let d = date(day), let moved = utc.date(byAdding: .day, value: days, to: d) else { return day }
        return string(moved)
    }

    private static func dayCount(from: String, to: String) -> Int {
        guard let a = date(from), let b = date(to) else { return 0 }
        return (utc.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }

    static func key(for day: String, group: Group) -> String {
        switch group {
        case .day: return day
        case .month: return String(day.prefix(7))
        case .year: return String(day.prefix(4))
        case .week:
            guard let d = date(day), let start = utc.dateInterval(of: .weekOfYear, for: d)?.start else { return day }
            return "week of " + string(start)
        }
    }

    /// Every group key from `from` to `to`, oldest first, so empty groups show as a dash.
    private static func groupKeys(from: String, to: String, group: Group) -> [String] {
        guard var cursor = date(from), let end = date(to) else { return [] }
        var keys: [String] = []
        var seen = Set<String>()
        let step: Calendar.Component = group == .day ? .day : group == .week ? .weekOfYear : group == .month ? .month : .year
        while cursor <= end {
            let k = key(for: string(cursor), group: group)
            if seen.insert(k).inserted { keys.append(k) }
            guard let next = utc.date(byAdding: step, value: 1, to: cursor) else { break }
            // Months and years step from the first of the period, so a 31st never skips a short month.
            switch group {
            case .month: cursor = utc.date(from: utc.dateComponents([.year, .month], from: next)) ?? next
            case .year: cursor = utc.date(from: utc.dateComponents([.year], from: next)) ?? next
            default: cursor = next
            }
        }
        let last = key(for: to, group: group)
        if seen.insert(last).inserted { keys.append(last) }
        return keys
    }

    private static func groupCount(from: String, to: String, group: Group) -> Int {
        guard let a = date(from), let b = date(to) else { return 0 }
        switch group {
        case .day: return dayCount(from: from, to: to)
        case .week: return (utc.dateComponents([.day], from: a, to: b).day ?? 0) / 7 + 2
        case .month:
            let c = utc.dateComponents([.year, .month], from: a), e = utc.dateComponents([.year, .month], from: b)
            return ((e.year ?? 0) - (c.year ?? 0)) * 12 + ((e.month ?? 0) - (c.month ?? 0)) + 1
        case .year: return (utc.component(.year, from: b) - utc.component(.year, from: a)) + 1
        }
    }

    private static func weekday(_ day: String) -> String {
        guard let d = date(day) else { return "" }
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][utc.component(.weekday, from: d) - 1]
    }

    static func format(_ v: Double, _ metric: CoachChartMetric) -> String {
        switch metric {
        case .steps, .activeCalories, .charge, .effort: return String(format: "%.0f", v)
        case .skinTemp: return String(format: "%+.2f", v)
        case .sleepHours: return String(format: "%.2f", v)
        default: return String(format: "%.1f", v)
        }
    }

    private static func contextFields(_ d: DailyMetric, excluding metric: CoachChartMetric) -> String {
        var parts: [String] = []
        if metric != .charge, let c = d.recovery { parts.append("charge \(Int(c.rounded()))") }
        if metric != .sleepHours, let s = d.totalSleepMin { parts.append(String(format: "sleep %.1f h", s / 60)) }
        if metric != .hrv, let h = d.avgHrv { parts.append(String(format: "HRV %.0f ms", h)) }
        if metric != .effort, let e = d.strain { parts.append(String(format: "effort %.0f", e)) }
        return parts.joined(separator: ", ")
    }

    private static func coverageHint(_ rows: [DailyMetric], metric: CoachChartMetric) -> String {
        let all = rows.compactMap { d in metric.value(d).flatMap { $0.isFinite ? d.day : nil } }.sorted()
        guard let first = all.first, let last = all.last else { return " There is no \(metric.title) data at all yet." }
        return " \(metric.title) exists on \(all.count) days from \(first) to \(last)."
    }
}
