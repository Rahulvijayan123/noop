import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Heart-rate zones over a range
//
// Opened from the Workouts page. Zone minutes per week (per day for a week, per month beyond three months) as
// stacked bars, the range's total in each zone as bars, and where the figures come from. A workout imported
// with a zone split (WHOOP) uses it as it is; one without is binned from the strap's own heart rate over its
// window, the same read and the same %HRmax zones its detail page uses, and is drawn as an estimate. The
// readout says how many sessions each kind covers, so a split from three of nine sessions never reads as
// the whole range.

struct WorkoutZonesView: View {
    /// Every loaded session (already through the page's filters); the range cuts it here.
    let rows: [WorkoutRow]

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var range: ChartRange
    @State private var selected: Date?
    /// Zone minutes binned from the strap's heart rate, by session start, for sessions with no imported
    /// split. Filled per range; a session the strap did not record is absent.
    @State private var estimated: [Int: [Double]] = [:]
    @State private var estimating = true
    /// Sessions already read (with or without heart rate), so a range change never reads one twice.
    @State private var tried: Set<Int> = []

    /// How many sessions without an imported split one range reads from the strap. The reads are per
    /// workout (the detail page's own read), so a long range stops at the newest ones.
    static let estimateCap = 60

    init(rows: [WorkoutRow], initialRange: ChartRange) {
        self.rows = rows
        _range = State(initialValue: initialRange)
    }

    var body: some View {
        let window = WorkoutTraining.window(range, rows: rows)
        let inRange = range == .all ? rows : WorkoutTraining.rows(rows, in: window)
        let bin = WorkoutTraining.bin(for: range, window: window)
        let sources = Self.zoneSources(inRange, estimated: estimated)
        let days = Self.zoneDays(sources, bin: bin)
        let totals = Self.totals(sources)
        let imported = sources.filter { !$0.isEstimate }.count
        let estimatedCount = sources.count - imported
        let loading = estimating && sources.isEmpty
        ScreenScaffold(title: "Heart rate zones", titleDisplay: .navigationBar) {
            ValueReadout(readout(days: days, bin: bin, sources: sources, totals: totals, sessions: inRange.count,
                                 imported: imported, estimated: estimatedCount),
                         isScrubbing: selected != nil, isLoading: loading)
            RangeControl(selection: $range, options: WorkoutTraining.ranges,
                         isAvailable: { WorkoutTraining.isAvailable($0, oldestTs: rows.map(\.startTs).min()) })
            NoopCard {
                StackedBarChart(days: days, categories: WorkoutZoneMath.categories, bin: bin,
                                state: loading ? .loading
                                    : (sources.isEmpty ? .empty(String(localized: "No zone data in this range")) : .ready),
                                window: window, xStyle: range.axisStyle, y: .durationMinutes(minSpanMinutes: 60),
                                selection: $selected, accessibilityTitle: String(localized: "Heart rate zones"))
            }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Time in zones", trailing: estimatedCount > 0 ? String(localized: "Estimate") : nil)
                    NoopCard { WorkoutZoneBars(minutes: totals) }
                }
                StatGrid(stats(sources: sources, totals: totals), columns: 2)
            }
            AboutDisclosure("About heart rate zones", paragraphs: [
                String(localized: "Share of imported zone time, duration-weighted across sessions (approximate)."),
                String(localized: "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate)."),
                String(localized: "Sessions with neither an imported split nor strap heart rate are not counted."),
            ])
        }
        .onChangeCompat(of: range) { _ in selected = nil }
        .task(id: "\(range.rawValue)|\(profile.hrMax)|\(inRange.count)") {
            await estimate(inRange)
        }
    }

    // MARK: Reading the strap

    /// Bins the strap's heart rate into zones for the range's sessions that carry no imported split, newest
    /// first, up to `estimateCap`. The read is `Repository.workoutZoneMinutes`, exactly as the workout's own
    /// page calls it; nothing is stored.
    private func estimate(_ inRange: [WorkoutRow]) async {
        estimating = true
        let pending = inRange
            .filter { WorkoutZoneMath.minutes($0) == nil && !tried.contains($0.startTs) }
            .sorted { $0.startTs > $1.startTs }
            .prefix(Self.estimateCap)
        var found = estimated
        var read = tried
        for row in pending {
            if Task.isCancelled { return }
            read.insert(row.startTs)
            if let minutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs,
                                                           zoneSet: profile.hrZoneSet, source: row.source) {
                found[row.startTs] = minutes
            }
        }
        guard !Task.isCancelled else { return }
        estimated = found
        tried = read
        estimating = false
    }

    // MARK: Readout and statistics

    private func readout(days: [StackedBarChart.Day], bin: Calendar.Component, sources: [ZoneSource],
                         totals: [Double], sessions: Int, imported: Int, estimated: Int) -> ReadoutContent {
        let format: (Double) -> String = { WorkoutFormat.duration(minutes: $0) }
        if let selected {
            let points = days.map { DailyPoint(day: $0.day, value: $0.values.values.reduce(0, +), isEstimate: $0.isEstimate) }
            let n = sources.filter {
                Calendar.current.dateInterval(of: bin, for: $0.start)?.contains(selected) ?? false
            }.count
            return .daily(selection: selected, in: points, bin: bin, unit: nil, format: format,
                          context: n == 0 ? nil : WorkoutTraining.sessionCount(n))
        }
        let context: String
        if estimated > 0 && imported > 0 {
            context = String(localized: "\(imported) imported, \(estimated) estimated of \(sessions) sessions")
        } else {
            context = String(localized: "From \(sources.count) of \(sessions) sessions")
        }
        return ReadoutContent(dateLine: String(localized: "Time in zones"),
                              value: sources.isEmpty ? nil : format(totals.reduce(0, +)), unit: nil,
                              context: context, isEstimate: estimated > 0 && imported == 0)
    }

    private func stats(sources: [ZoneSource], totals: [Double]) -> [StatItem] {
        let total = totals.reduce(0, +)
        let hard = totals.count == 5 ? totals[3] + totals[4] : 0
        let days = Set(sources.map { Calendar.current.startOfDay(for: $0.start) })
        return [
            StatItem(String(localized: "Total"), value: WorkoutFormat.duration(minutes: total)),
            StatItem(String(localized: "Per workout day"),
                     value: days.isEmpty ? nil : WorkoutFormat.duration(minutes: total / Double(days.count))),
            StatItem(String(localized: "Z4–5 share"), value: total > 0 ? "\(Int((hard / total * 100).rounded()))" : nil,
                     unit: "%"),
            StatItem(String(localized: "Active days"), value: "\(days.count)"),
        ]
    }

    // MARK: Aggregation (display only)

    /// One session's zone minutes and whether they are the strap-derived estimate.
    struct ZoneSource {
        let start: Date
        let minutes: [Double]
        let isEstimate: Bool
    }

    /// Imported splits first-hand; strap-derived minutes for the rest, where the strap recorded the session.
    static func zoneSources(_ rows: [WorkoutRow], estimated: [Int: [Double]]) -> [ZoneSource] {
        rows.compactMap { r in
            let start = Date(timeIntervalSince1970: TimeInterval(r.startTs))
            if let m = WorkoutZoneMath.minutes(r) { return ZoneSource(start: start, minutes: m, isEstimate: false) }
            if let m = estimated[r.startTs], m.count == 5 { return ZoneSource(start: start, minutes: m, isEstimate: true) }
            return nil
        }
    }

    /// Imported splits only (the rows alone), for callers that hold no strap reads.
    static func zoneSources(_ rows: [WorkoutRow]) -> [ZoneSource] { zoneSources(rows, estimated: [:]) }

    /// Zone minutes per bin, summed (a week's bar is that week's total, not its average day): each bin is
    /// handed to the chart as one day at the bin's start, so the chart's own mean-per-bin keeps the total. A
    /// bin is drawn as an estimate when most of its minutes are.
    static func zoneDays(_ sources: [ZoneSource], bin: Calendar.Component, calendar: Calendar = .current) -> [StackedBarChart.Day] {
        var byBin: [Date: (minutes: [Double], estimate: Double)] = [:]
        for s in sources {
            let start = calendar.dateInterval(of: bin, for: s.start)?.start ?? calendar.startOfDay(for: s.start)
            var acc = byBin[start] ?? ([0, 0, 0, 0, 0], 0)
            for i in 0..<5 { acc.minutes[i] += s.minutes[i] }
            if s.isEstimate { acc.estimate += s.minutes.reduce(0, +) }
            byBin[start] = acc
        }
        return byBin.keys.sorted().map { start in
            let acc = byBin[start] ?? ([], 0)
            let total = acc.minutes.reduce(0, +)
            return StackedBarChart.Day(
                day: start,
                values: Dictionary(uniqueKeysWithValues: acc.minutes.enumerated().map { ("z\($0.offset + 1)", $0.element) }),
                isEstimate: total > 0 && acc.estimate * 2 >= total)
        }
    }

    /// The range's minutes in each zone.
    static func totals(_ sources: [ZoneSource]) -> [Double] {
        var acc = [Double](repeating: 0, count: 5)
        for s in sources { for i in 0..<5 { acc[i] += s.minutes[i] } }
        return acc
    }
}
