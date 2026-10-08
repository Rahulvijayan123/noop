import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Workouts: shared presentation pieces
//
// Formatting, display-only aggregation and the few views the Workouts pages share (the session row, the
// zone bars). Everything here lays out values the pages already hold: it reads nothing from the store,
// computes no score and changes no stored row. The aggregation is a plain reduce over `WorkoutRow`s already
// in memory (training minutes per day, zone minutes from the imported percentages).

enum WorkoutFormat {
    /// "38 min", "1 h 12 m", "2 h" (the same localized patterns the stretch lists use).
    static func duration(minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m) min") }
        let h = m / 60, r = m % 60
        return r == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(r) m")
    }

    /// The row's duration, nil when it has none.
    static func duration(seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return duration(minutes: seconds / 60)
    }

    /// "18:40–19:18" or "6:40–7:18 PM" through `AppClock`, so the Clock format setting reaches it (#1821).
    static func timeRange(_ start: Int, _ end: Int) -> String {
        let f = AppClock.hourMinuteFormatter()
        let a = f.string(from: Date(timeIntervalSince1970: TimeInterval(start)))
        guard end > start else { return a }
        return "\(a)–\(f.string(from: Date(timeIntervalSince1970: TimeInterval(end))))"
    }

    /// "Tue 7 Oct" (the year added outside the current year), the kit's day line.
    static func day(_ ts: Int) -> String {
        ReadoutContent.dateLine(Date(timeIntervalSince1970: TimeInterval(ts)), period: .day)
    }

    static func grouped(_ v: Double) -> String {
        intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// A distance split into its number and unit, so the unit can sit beside the value in its own colour.
    static func distance(meters: Double, system: UnitSystem) -> (value: String, unit: String) {
        let full = UnitFormatter.distanceFromMeters(meters, system: system)
        guard let space = full.lastIndex(of: " ") else { return (full, "") }
        return (String(full[..<space]), String(full[full.index(after: space)...]))
    }

    /// A pace split the same way ("5:12", "/km").
    static func pace(secPerKm: Double?, system: UnitSystem) -> (value: String, unit: String)? {
        guard let secPerKm, secPerKm > 0 else { return nil }
        let full = UnitFormatter.paceFromSecPerKm(secPerKm, system: system)
        guard let space = full.lastIndex(of: " ") else { return (full, "") }
        return (String(full[..<space]), String(full[full.index(after: space)...]))
    }

    /// The source a row came from, in words.
    static func source(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .whoop:        return String(localized: "Whoop")
        case .apple:        return String(localized: "Apple Health")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    /// The source in one short word, for list rows ("Apple", "Whoop", "Manual").
    static func shortSource(_ source: String) -> String {
        WorkoutSource.classify(source) == .apple ? String(localized: "Apple") : Self.source(source)
    }

    /// The stored 0-100 Effort on the user's scale, plus its "of 100" / "of 21" denominator.
    static func effort(_ strain: Double?, scale: EffortScale) -> (value: String, of: String)? {
        guard let strain else { return nil }
        return (UnitFormatter.effortDisplay(strain, scale: scale),
                String(localized: "of \(UnitFormatter.effortScaleMax(scale))"))
    }

    /// "last 7 days" → "Last 7 days": the range captions are stored lower-case for use mid-sentence.
    static func sentenceStart(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

// MARK: - Training time over a range

enum WorkoutTraining {
    /// The ranges the Workouts pages offer.
    static let ranges: [ChartRange] = [.week, .month, .quarter, .year, .all]

    /// Minutes of training per local day, one point per day with a workout. A row without a duration
    /// counts as nothing (the same rule the old Total Time tile used).
    static func minutesPerDay(_ rows: [WorkoutRow], calendar: Calendar = .current) -> [DailyPoint] {
        var byDay: [Date: Double] = [:]
        for r in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.startTs)))
            byDay[day, default: 0] += (r.durationS ?? 0) / 60
        }
        return byDay.keys.sorted().map { DailyPoint(day: $0, value: byDay[$0] ?? 0) }
    }

    /// One bar per day for a week, per week for a month or three, per month beyond that.
    static func bin(for range: ChartRange, window: ClosedRange<Date>, calendar: Calendar = .current) -> Calendar.Component {
        switch range {
        case .week: return .day
        case .month, .quarter: return .weekOfYear
        case .half, .year: return .month
        case .all:
            let days = ChartDay.daysBetween(window.lowerBound, window.upperBound, calendar: calendar)
            return days <= 31 ? .day : (days <= 200 ? .weekOfYear : .month)
        }
    }

    /// The x window for a range: the range ending today, `.all` from the first workout.
    static func window(_ range: ChartRange, rows: [WorkoutRow], calendar: Calendar = .current) -> ClosedRange<Date> {
        let first = rows.map(\.startTs).min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return ChartAxis.window(range, firstDataDay: first, calendar: calendar)
    }

    /// Rows whose start falls inside `window`.
    static func rows(_ rows: [WorkoutRow], in window: ClosedRange<Date>) -> [WorkoutRow] {
        let lo = Int(window.lowerBound.timeIntervalSince1970), hi = Int(window.upperBound.timeIntervalSince1970)
        return rows.filter { $0.startTs >= lo && $0.startTs <= hi }
    }

    /// Rows inside the calendar `unit` that contains `date` (the bar under a selection).
    static func rows(_ rows: [WorkoutRow], inBinOf date: Date, unit: Calendar.Component,
                     calendar: Calendar = .current) -> [WorkoutRow] {
        guard let interval = calendar.dateInterval(of: unit, for: date) else { return [] }
        return rows.filter {
            let t = Date(timeIntervalSince1970: TimeInterval($0.startTs))
            return t >= interval.start && t < interval.end
        }
    }

    /// Whether a range adds anything over the next smaller one for a history starting at `oldestTs`.
    static func isAvailable(_ range: ChartRange, oldestTs: Int?, now: Date = Date()) -> Bool {
        guard let oldestTs else { return false }
        let ageDays = Int(now.timeIntervalSince1970) - oldestTs
        switch range {
        case .week: return true
        case .month: return ageDays > 7 * 86_400
        case .quarter: return ageDays > 30 * 86_400
        case .half, .year: return ageDays > 90 * 86_400
        case .all: return true
        }
    }

    /// "1 session" / "3 sessions".
    static func sessionCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 session") : String(localized: "\(n) sessions")
    }
}

// MARK: - Sports

struct WorkoutSportGroup: Identifiable {
    let sport: String
    let count: Int
    let totalTimeS: Double
    let totalKcal: Double
    var id: String { sport }
}

enum WorkoutSports {
    /// Sessions grouped by sport, most sessions first, then most time.
    static func groups(_ rows: [WorkoutRow]) -> [WorkoutSportGroup] {
        var bySport: [String: (count: Int, time: Double, kcal: Double)] = [:]
        for r in rows {
            var acc = bySport[r.sport] ?? (0, 0, 0)
            acc.count += 1
            acc.time += r.durationS ?? 0
            acc.kcal += r.energyKcal ?? 0
            bySport[r.sport] = acc
        }
        return bySport
            .map { WorkoutSportGroup(sport: $0.key, count: $0.value.count,
                                     totalTimeS: $0.value.time, totalKcal: $0.value.kcal) }
            .sorted { ($0.count, $0.totalTimeS) > ($1.count, $1.totalTimeS) }
    }
}

// MARK: - Zones

enum WorkoutZoneMath {
    /// Zone minutes for one row from its imported percentages (duration × pct ÷ 100), the same reduce
    /// `WorkoutZones.summary` and the detail page apply. nil when the row carries no zones.
    static func minutes(_ row: WorkoutRow) -> [Double]? {
        guard let pct = WorkoutZones.percents(row.zonesJSON) else { return nil }
        let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
        guard durMin > 0 else { return nil }
        return pct.map { durMin * $0 / 100.0 }
    }

    static let categories: [StackedBarChart.Category] = (1...5).map {
        StackedBarChart.Category(id: "z\($0)", name: "Z\($0)", color: StrandPalette.hrZoneColor($0))
    }
}

/// Time in each heart-rate zone as five horizontal bars, so each zone's minutes are readable on their own
/// (a single stacked strip hides the small zones). Bars are scaled to the busiest zone; the row says the
/// minutes and the share of the total.
struct WorkoutZoneBars: View {
    let minutes: [Double]
    /// Optional "120–138 bpm" per zone, when the zone model behind the minutes is the user's own.
    var ranges: [String?] = []
    var isLoading = false

    var body: some View {
        let values = isLoading ? [6, 14, 10, 5, 2] : minutes
        let total = max(values.reduce(0, +), 0.001)
        let peak = max(values.max() ?? 0, 0.001)
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(0..<5, id: \.self) { i in
                let value = i < values.count ? values[i] : 0
                HStack(spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "Z\(i + 1)")
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let range = i < ranges.count ? ranges[i] : nil {
                            Text(range)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(width: ranges.contains(where: { $0 != nil }) ? 76 : 28, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(StrandPalette.surfaceInset)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(StrandPalette.hrZoneColor(i + 1))
                                .frame(width: value > 0 ? max(3, geo.size.width * value / peak) : 0)
                        }
                    }
                    .frame(height: 10)
                    Text(isLoading ? "00 min · 00 %"
                         : "\(WorkoutFormat.duration(minutes: value)) · \(Int((value / total * 100).rounded())) %")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .frame(width: 104, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Zone \(i + 1)"))
                .accessibilityValue(isLoading ? "" : "\(WorkoutFormat.duration(minutes: value)), \(Int((value / total * 100).rounded())) %")
            }
        }
        .redacted(reason: isLoading ? .placeholder : [])
    }
}

// MARK: - Session row

/// One workout in a list: sport, when, how long. The trailing column is reserved for the actions menu the
/// list lays over it (outside the row's own tap target, the #318 idiom).
struct WorkoutSessionRow: View {
    let row: WorkoutRow
    let effortScale: EffortScale
    var showsDay = false
    var selection: Selection? = nil
    /// What sits at the trailing edge: room for the list's "•••" menu, a chevron, or nothing.
    var accessory: Accessory = .menu

    enum Selection { case selected, unselected, locked }
    enum Accessory { case menu, chevron, none }

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            if let selection {
                Group {
                    switch selection {
                    case .selected:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
                    case .unselected:
                        Image(systemName: "circle").foregroundStyle(StrandPalette.textTertiary)
                    case .locked:
                        Image(systemName: "lock.fill").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .font(StrandFont.icon(.row))
                .frame(width: 24)
                .accessibilityHidden(true)
            }
            Image(systemName: sportSymbol(row.sport))
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(WorkoutSource.displaySport(row.sport))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NoopMetrics.space2)
            VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                Text(WorkoutFormat.duration(seconds: row.durationS) ?? "—")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                if row.strain != nil {
                    Text(String(localized: "Effort \(WorkoutsView.effortCellLabel(strain: row.strain, scale: effortScale))"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .fixedSize()
            switch accessory {
            case .menu: Color.clear.frame(width: 28, height: 1)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            case .none: EmptyView()
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "6:40 PM–7:18 PM · Apple" (the day instead of the time on lists that are not grouped by day).
    var subtitle: String {
        var parts: [String] = []
        parts.append(showsDay ? WorkoutFormat.day(row.startTs) : WorkoutFormat.timeRange(row.startTs, row.endTs))
        parts.append(WorkoutFormat.shortSource(row.source))
        return parts.joined(separator: " · ")
    }

    /// Everything the row says, for VoiceOver.
    var accessibilitySummary: String {
        var parts = [WorkoutFormat.day(row.startTs), WorkoutFormat.timeRange(row.startTs, row.endTs)]
        if row.strain != nil {
            parts.append(String(localized: "Effort \(WorkoutsView.effortCellLabel(strain: row.strain, scale: effortScale))"))
        }
        parts.append(WorkoutFormat.source(row.source))
        return parts.joined(separator: ", ")
    }
}

/// The trailing "•••" that opens a row's actions, laid over the row's reserved column.
struct WorkoutRowMenuButton<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Actions"))
    }
}

/// Rows of one day under a day label, in one card.
struct WorkoutDayGroup<Row: View>: View {
    let title: String
    let rows: [WorkoutRow]
    @ViewBuilder let row: (WorkoutRow) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.subhead.weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.leading, NoopMetrics.space1)
                .accessibilityAddTraits(.isHeader)
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.listID) { index, r in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        row(r)
                    }
                }
            }
        }
    }
}

/// One local day of sessions.
struct WorkoutDay: Identifiable {
    let day: Date
    let rows: [WorkoutRow]
    var id: Date { day }

    /// Rows grouped by local day, newest day first, newest row first inside a day.
    static func group(_ rows: [WorkoutRow], calendar: Calendar = .current) -> [WorkoutDay] {
        let grouped = Dictionary(grouping: rows) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        return grouped.keys.sorted(by: >).map { day in
            WorkoutDay(day: day, rows: (grouped[day] ?? []).sorted { $0.startTs > $1.startTs })
        }
    }
}

extension WorkoutRow {
    /// The natural key ("startTs|sport") the list, selection and route store share.
    var naturalKey: String { "\(startTs)|\(sport)" }
    /// A list identity that also separates two sources' rows for the same start and sport.
    var listID: String { "\(startTs)|\(sport)|\(source)" }
}

/// A placeholder list at its final size, for the loading state.
struct WorkoutRowsPlaceholder: View {
    var count = 3
    var body: some View {
        NoopCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    if i > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                    NoopListRow(icon: "figure.run", title: "Workout name", subtitle: "00:00–00:00 · Source",
                                value: "00 min", showsChevron: false)
                }
            }
        }
        .loadingPlaceholder(true)
    }
}
