import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - One sport over time
//
// Opened from "By sport" on the Workouts page. The sport's training time per week (the readout follows the
// scrub), its statistics for the range, the effort of each session over time (a different question from the
// time spent: whether the sessions are getting harder or easier), its zone split when its sessions carry one,
// and its sessions, each opening its detail page.

struct WorkoutSportView: View {
    let sport: String
    /// This sport's sessions (every loaded one, through the page's filters); the range cuts them here.
    let rows: [WorkoutRow]

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .imperial, override: distanceSystemRaw)
    }
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    @State private var range: ChartRange
    @State private var selectedBar: Date?
    @State private var selectedEffort: Date?
    @State private var showsAll = false

    init(sport: String, rows: [WorkoutRow], initialRange: ChartRange) {
        self.sport = sport
        self.rows = rows
        _range = State(initialValue: initialRange)
    }

    var body: some View {
        let window = WorkoutTraining.window(range, rows: rows)
        let inRange = range == .all ? rows : WorkoutTraining.rows(rows, in: window)
        let bin = WorkoutTraining.bin(for: range, window: window)
        let points = WorkoutTraining.minutesPerDay(inRange)
        ScreenScaffold(title: "\(WorkoutSource.displaySport(sport))", titleDisplay: .navigationBar, lazy: true) {
            ValueReadout(readout(inRange: inRange, points: points, bin: bin), isScrubbing: selectedBar != nil)
            RangeControl(selection: $range, options: WorkoutTraining.ranges,
                         isAvailable: { WorkoutTraining.isAvailable($0, oldestTs: rows.map(\.startTs).min()) })
            NoopCard {
                DailyBarChart.totals(points, color: StrandPalette.effortColor, goal: nil, bin: bin,
                                     aggregation: .sum, legend: [],
                                     state: inRange.isEmpty ? .empty(String(localized: "No workouts in this range")) : .ready,
                                     window: window, xStyle: range.axisStyle, y: .durationMinutes(minSpanMinutes: 60),
                                     selection: $selectedBar, accessibilityTitle: String(localized: "Training time"))
            }
            StatGrid(stats(inRange), columns: 2)
            effortCard(window: window)
            zonesCard(inRange)
            sessions(inRange)
        }
        .onChangeCompat(of: range) { _ in
            selectedBar = nil
            selectedEffort = nil
            showsAll = false
        }
    }

    private func readout(inRange: [WorkoutRow], points: [DailyPoint], bin: Calendar.Component) -> ReadoutContent {
        let format: (Double) -> String = { WorkoutFormat.duration(minutes: $0) }
        if let selectedBar {
            let binned = DailyBarChart.bin(points, by: bin, aggregation: .sum)
            let n = WorkoutTraining.rows(inRange, inBinOf: selectedBar, unit: bin).count
            return .daily(selection: selectedBar, in: binned, bin: bin, unit: nil, format: format,
                          context: WorkoutTraining.sessionCount(n))
        }
        let minutes = inRange.compactMap(\.durationS).reduce(0, +) / 60
        return ReadoutContent(dateLine: String(localized: "Training time"), value: format(minutes), unit: nil,
                              context: WorkoutTraining.sessionCount(inRange.count))
    }

    private func stats(_ rows: [WorkoutRow]) -> [StatItem] {
        let durations = rows.compactMap(\.durationS).filter { $0 > 0 }
        let avgMin = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count) / 60
        let strains = rows.compactMap(\.strain)
        let effort = WorkoutFormat.effort(strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count),
                                          scale: effortScale)
        let kcal = rows.compactMap(\.energyKcal)
        let distancesM = rows.compactMap(\.distanceM).filter { $0 > 0 }
        var items = [
            StatItem(String(localized: "Avg session"), value: avgMin.map { WorkoutFormat.duration(minutes: $0) }),
            StatItem(String(localized: "Typical effort"), value: effort?.value, detail: effort?.of),
        ]
        if distancesM.isEmpty {
            items.append(StatItem(String(localized: "Calories"),
                                  value: kcal.isEmpty ? nil : WorkoutFormat.grouped(kcal.reduce(0, +)), unit: "kcal"))
            let hrs = rows.compactMap(\.avgHr)
            items.append(StatItem(String(localized: "Avg HR"),
                                  value: hrs.isEmpty ? nil : "\(Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded()))",
                                  unit: "bpm"))
        } else {
            let d = WorkoutFormat.distance(meters: distancesM.reduce(0, +), system: distanceUnitSystem)
            items.append(StatItem(String(localized: "Distance"), value: d.value, unit: d.unit))
            let secs = rows.filter { ($0.distanceM ?? 0) > 0 }.compactMap(\.durationS).reduce(0, +)
            let pace = WorkoutFormat.pace(secPerKm: secs > 0 ? secs / (distancesM.reduce(0, +) / 1000) : nil,
                                          system: distanceUnitSystem)
            items.append(StatItem(String(localized: "Avg pace"), value: pace?.value, unit: pace?.unit))
        }
        return items
    }

    // MARK: Effort per session

    /// Each day's session effort on the user's scale (the mean when a day has two), a point per day with a
    /// faint trend, on the scale's fixed axis.
    private func effortPoints() -> [DailyPoint] {
        var byDay: [Date: [Double]] = [:]
        for r in rows {
            guard let s = r.strain else { continue }
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.startTs)))
            byDay[day, default: []].append(UnitFormatter.effortValue(s, scale: effortScale))
        }
        return byDay.keys.sorted().map { DailyPoint(day: $0, value: (byDay[$0] ?? []).reduce(0, +) / Double(max(1, byDay[$0]?.count ?? 1))) }
    }

    @ViewBuilder
    private func effortCard(window: ClosedRange<Date>) -> some View {
        let points = effortPoints()
        if !points.isEmpty {
            let scaleMax: Double = effortScale == .whoop ? 21 : 100
            let picked = ChartSelection.point(for: selectedEffort, in: points)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Effort per session",
                              trailing: picked.map { "\(ReadoutContent.dateLine($0.day, period: .day)) · \(String(format: "%.1f", $0.value))" })
                NoopCard {
                    SparsePointsChart(points: points, cadence: .sparse(maxGapDays: 21), color: StrandPalette.effortColor,
                                      window: window, xStyle: range.axisStyle,
                                      y: ChartValueAxis(unit: nil, domain: .fixed(0...scaleMax)),
                                      selection: $selectedEffort, height: NoopMetrics.chartHeightSecondary,
                                      accessibilityTitle: String(localized: "Effort per session"))
                }
            }
        }
    }

    // MARK: Zones

    @ViewBuilder
    private func zonesCard(_ rows: [WorkoutRow]) -> some View {
        let withZones = rows.filter { WorkoutZoneMath.minutes($0) != nil }
        if !withZones.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Time in zones",
                              trailing: String(localized: "From \(withZones.count) of \(rows.count) sessions"))
                NoopCard { WorkoutZoneBars(minutes: WorkoutZonesView.totals(WorkoutZonesView.zoneSources(withZones))) }
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private func sessions(_ rows: [WorkoutRow]) -> some View {
        if !rows.isEmpty {
            let sorted = rows.sorted { $0.startTs > $1.startTs }
            let shown = showsAll ? sorted : Array(sorted.prefix(WorkoutsView.currentScopeCount))
            SectionHeader("Sessions", trailing: WorkoutTraining.sessionCount(rows.count))
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.listID) { index, row in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        NavigationLink {
                            WorkoutDetailView(row: row, presentation: .pushed)
                        } label: {
                            WorkoutSessionRow(row: row, effortScale: effortScale, showsDay: true, accessory: .chevron)
                        }
                        .buttonStyle(.plain)
                    }
                    if shown.count < sorted.count {
                        NoopListDivider(leadingInset: 0)
                        Button { showsAll = true } label: {
                            HStack {
                                Text("Show all")
                                    .font(StrandFont.subhead.weight(.medium))
                                    .foregroundStyle(StrandPalette.accent)
                                Spacer(minLength: NoopMetrics.space2)
                                Text("\(sorted.count)")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .padding(.horizontal, NoopMetrics.cardPadding)
                            .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
