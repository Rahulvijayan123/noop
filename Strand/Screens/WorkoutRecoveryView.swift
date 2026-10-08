import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Heart-rate recovery across workouts (#516)
//
// Opened from the Workouts page. How far the heart rate fell 1, 2 or 5 minutes after each eligible workout,
// as points over time with a faint trend (recovery is read only after high-intensity sessions, so the
// readings are irregular). The readout follows the scrub; the list below names each workout. The figures are
// the ones the Workouts page computed for its range (capped at 90 days); nothing is re-read here.

struct WorkoutRecoveryView: View {
    let points: [WorkoutRecoveryTrendPoint]
    /// The loaded sessions, to name the workout behind each reading.
    let rows: [WorkoutRow]

    enum Interval: Hashable, CaseIterable {
        case one, two, five
        var label: String {
            switch self {
            case .one: return String(localized: "1 min")
            case .two: return String(localized: "2 min")
            case .five: return String(localized: "5 min")
            }
        }
        func value(_ r: HeartRateRecovery.Result) -> Int? {
            switch self {
            case .one: return r.after1Minute
            case .two: return r.after2Minutes
            case .five: return r.after5Minutes
            }
        }
    }

    @State private var interval: Interval = .one
    @State private var selected: Date?
    @State private var showsAll = false

    var body: some View {
        let daily = dailyPoints
        let window = ChartAxis.window(.all, firstDataDay: daily.first?.day)
        let values = points.compactMap { interval.value($0.result) }
        ScreenScaffold(title: "Heart rate recovery", titleDisplay: .navigationBar) {
            ValueReadout(readout(daily), isScrubbing: selected != nil)
            SegmentedPillControl(Interval.allCases, selection: $interval, fillsAvailableWidth: true) { $0.label }
            NoopCard {
                SparsePointsChart(points: daily, cadence: .sparse(maxGapDays: 21), color: StrandPalette.metricRose,
                                  references: values.contains(where: { $0 < 0 }) ? [ChartReference(0)] : [],
                                  state: daily.isEmpty ? .empty(String(localized: "No eligible workouts yet")) : .ready,
                                  window: window, xStyle: .dayOfMonth,
                                  y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 20, includeZero: true)),
                                  selection: $selected, accessibilityTitle: String(localized: "Heart rate recovery"))
            }
            if !values.isEmpty {
                StatGrid([
                    StatItem(String(localized: "Average"),
                             value: "\(Int((Double(values.reduce(0, +)) / Double(values.count)).rounded()))", unit: "bpm"),
                    StatItem(String(localized: "Best"), value: values.max().map { "\($0)" }, unit: "bpm"),
                    StatItem(String(localized: "Low"), value: values.min().map { "\($0)" }, unit: "bpm"),
                    StatItem(String(localized: "Workouts"), value: "\(values.count)"),
                ], columns: 2)
                ReadingsList(rows: readings, visibleCount: showsAll ? readings.count : 7,
                             onShowAll: { showsAll = true })
            }
            AboutDisclosure("About heart rate recovery", paragraphs: [
                String(localized: "Each line shows how many beats per minute your heart rate changed after exercise. Only high-intensity workouts with recorded post-workout heart rate are included."),
                String(localized: "The change from your heart rate at the end of exercise. Positive values mean your heart rate fell; a dash means the strap did not record enough data around that minute."),
            ])
        }
        .onChangeCompat(of: interval) { _ in selected = nil }
    }

    /// One point per day (the mean when a day holds two eligible workouts).
    private var dailyPoints: [DailyPoint] {
        var byDay: [Date: [Int]] = [:]
        for p in points {
            guard let v = interval.value(p.result) else { continue }
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(p.startTs)))
            byDay[day, default: []].append(v)
        }
        return byDay.keys.sorted().map { day in
            let vs = byDay[day] ?? []
            return DailyPoint(day: day, value: Double(vs.reduce(0, +)) / Double(max(1, vs.count)))
        }
    }

    private func readout(_ daily: [DailyPoint]) -> ReadoutContent {
        let base = ReadoutContent.daily(selection: selected, in: daily, unit: "bpm",
                                        format: { "\(Int($0.rounded()))" })
        let day = selected.map { Calendar.current.startOfDay(for: $0) } ?? daily.last?.day
        guard let day, let workout = latestWorkout(on: day) else { return base }
        var content = base
        content.context = "\(WorkoutSource.displaySport(workout.row.sport)) · \(String(localized: "Peak \(workout.point.result.endHR) bpm"))"
        return content
    }

    /// The newest eligible workout on a day, with its row.
    private func latestWorkout(on day: Date) -> (point: WorkoutRecoveryTrendPoint, row: WorkoutRow)? {
        let cal = Calendar.current
        let candidates = points
            .filter { cal.isDate(Date(timeIntervalSince1970: TimeInterval($0.startTs)), inSameDayAs: day) }
            .sorted { $0.startTs > $1.startTs }
        for p in candidates {
            if let row = rows.first(where: { $0.startTs == p.startTs }) { return (p, row) }
        }
        return nil
    }

    /// Every eligible workout, newest first: sport and day, and the drop at the chosen interval.
    private var readings: [ReadingsList.Row] {
        points.sorted { $0.startTs > $1.startTs }.map { p in
            let sport = rows.first(where: { $0.startTs == p.startTs }).map { WorkoutSource.displaySport($0.sport) }
            return ReadingsList.Row(id: "\(p.startTs)", date: WorkoutFormat.day(p.startTs),
                                    value: interval.value(p.result).map { "\($0) bpm" } ?? "—",
                                    source: sport)
        }
    }
}
