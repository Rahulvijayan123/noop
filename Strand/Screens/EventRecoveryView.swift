import SwiftUI
import StrandDesign

// MARK: - Recovery history
//
// How quickly the body came back after this event, against every other event with a recovery: the readout
// (this event, or the one under the finger), an optional same-kind filter, the time to recover of each event
// as a point over date with the typical (median) time as a reference, the statistics, and the history list.

struct RecoveryDetailsView: View {
    let event: HealthEvent
    let history: [HealthEvent]

    private enum Scope: Hashable { case all, sameKind }

    @State private var scope: Scope = .all
    @State private var range: ChartRange = .all
    @State private var selected: Date?
    @State private var showsAllRows = false

    private var past: [HealthEvent] {
        history.filter { $0.recovery != nil }.sorted { $0.date > $1.date }
    }

    /// `past`, or only the events of this kind when the filter asks for them.
    private var scoped: [HealthEvent] {
        scope == .all ? past : past.filter { $0.title == event.title }
    }

    /// Whether a same-kind filter would show something different from all events.
    private var offersKindFilter: Bool {
        let kind = past.filter { $0.title == event.title }.count
        return kind >= 2 && kind < past.count
    }

    private func average(_ events: [HealthEvent]) -> EventRecovery {
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let recoveries = events.compactMap(\.recovery)
        return EventRecovery(timeToRecover: mean(recoveries.compactMap(\.timeToRecover)),
                             hrvReturn: mean(recoveries.compactMap(\.hrvReturn)),
                             activityReturn: mean(recoveries.compactMap(\.activityReturn)))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// One event per day for the chart (the chart's x is a day): this event on its own day, else the newest
    /// event of that day.
    private var byDay: [Date: HealthEvent] {
        var out: [Date: HealthEvent] = [:]
        let cal = Calendar.current
        for e in scoped where e.recovery?.timeToRecover != nil {
            let day = cal.startOfDay(for: e.date)
            if let held = out[day], held.id == event.id || held.date > e.date { continue }
            out[day] = e
        }
        return out
    }

    private var points: [DailyPoint] {
        byDay.compactMap { day, e in
            e.recovery?.timeToRecover.map { DailyPoint(day: day, value: $0 / 60) }
        }.sorted { $0.day < $1.day }
    }

    private var typical: Double? {
        Self.median(scoped.compactMap { $0.recovery?.timeToRecover })
    }

    /// History span in days, for the range control.
    private var spanDays: Int {
        guard let first = points.first?.day, let last = points.last?.day else { return 0 }
        return ChartDay.daysBetween(first, max(last, Date())) + 1
    }

    var body: some View {
        let points = points
        let window = ChartAxis.window(range, firstDataDay: points.first?.day)
        ScreenScaffold(title: "Recovery history", titleDisplay: .navigationBar) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                ValueReadout(readout, isScrubbing: selected != nil)
                if offersKindFilter {
                    SegmentedPillControl([Scope.all, .sameKind], selection: $scope, fillsAvailableWidth: true) {
                        $0 == .all ? String(localized: "All events") : event.title
                    }
                }
                RangeControl(selection: $range, options: [.month, .quarter, .half, .year, .all],
                             isAvailable: { ($0.days ?? 0) <= spanDays })
            }
            NoopCard {
                SparsePointsChart(points: points, trend: points.count >= 8 ? .rollingMedian(days: 30) : .none,
                                  cadence: .sparse(maxGapDays: 60), color: StrandPalette.metricPurple,
                                  references: typical.map {
                                      [ChartReference($0 / 60, label: String(localized: "Typical \(EventFormat.duration($0))"))]
                                  } ?? [],
                                  legend: [],
                                  state: points.isEmpty ? .empty(String(localized: "No recoveries yet")) : .ready,
                                  window: window, xStyle: range.axisStyle,
                                  y: .durationMinutes(minSpanMinutes: 60),
                                  selection: $selected, accessibilityTitle: String(localized: "Time to recover"))
            }
            if !scoped.isEmpty {
                StatGrid(stats, columns: 3)
                historySection
            }
            AboutDisclosure(paragraphs: aboutParagraphs)
        }
        .onChangeCompat(of: range) { _ in selected = nil }
        .onChangeCompat(of: scope) { _ in selected = nil; showsAllRows = false }
    }

    // MARK: Readout

    private var readout: ReadoutContent {
        let cal = Calendar.current
        if let selected, let shown = byDay[cal.startOfDay(for: selected)] {
            let context = shown.recovery?.hrvReturn.map { String(localized: "HRV regained \(EventFormat.share($0)) %") }
            return ReadoutContent(dateLine: "\(shown.title) · \(EventFormat.dayAndTime(shown.date))",
                                  value: shown.recovery?.timeToRecover.map(EventFormat.duration), unit: nil,
                                  context: context)
        }
        if let selected {
            return ReadoutContent(dateLine: ReadoutContent.dateLine(selected, period: .day), value: nil, unit: nil)
        }
        let count = scoped.count
        let context = typical.map {
            count == 1 ? String(localized: "Typical \(EventFormat.duration($0)) across 1 event")
                       : String(localized: "Typical \(EventFormat.duration($0)) across \(count) events")
        }
        return ReadoutContent(dateLine: "\(event.title) · \(EventFormat.dayAndTime(event.date))",
                              value: event.recovery?.timeToRecover.map(EventFormat.duration), unit: nil,
                              context: context)
    }

    // MARK: Statistics

    private var stats: [StatItem] {
        let avg = average(scoped)
        let timed = scoped.filter { $0.recovery?.timeToRecover != nil }
        let fastest = timed.min { ($0.recovery?.timeToRecover ?? 0) < ($1.recovery?.timeToRecover ?? 0) }
        let slowest = timed.max { ($0.recovery?.timeToRecover ?? 0) < ($1.recovery?.timeToRecover ?? 0) }
        func day(_ e: HealthEvent?) -> String? { e.map { ReadoutContent.dateLine($0.date, period: .day) } }
        return [
            StatItem(String(localized: "Average"), value: avg.timeToRecover.map(EventFormat.duration)),
            StatItem(String(localized: "Fastest"), value: fastest?.recovery?.timeToRecover.map(EventFormat.duration),
                     detail: day(fastest)),
            StatItem(String(localized: "Slowest"), value: slowest?.recovery?.timeToRecover.map(EventFormat.duration),
                     detail: day(slowest)),
            StatItem(String(localized: "HRV regained"), value: avg.hrvReturn.map(EventFormat.share), unit: "%"),
            StatItem(String(localized: "Active again"), value: avg.activityReturn.map(EventFormat.duration)),
            StatItem(String(localized: "Events"), value: "\(scoped.count)"),
        ]
    }

    // MARK: History

    private var historySection: some View {
        let rows = showsAllRows ? scoped : Array(scoped.prefix(7))
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("History")
            NoopListSection {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                    NavigationLink(value: TabRoute.event(item, history: history)) {
                        NoopListRow(icon: item.symbol, iconColor: item.tone.color, title: verbatimKey(item.title),
                                    subtitle: subtitle(item),
                                    value: item.recovery?.timeToRecover.map(EventFormat.duration) ?? "—")
                    }
                }
                if scoped.count > 7 {
                    NoopListDivider(leadingInset: 0)
                    Button { showsAllRows.toggle() } label: {
                        Text(showsAllRows ? String(localized: "Show fewer") : String(localized: "Show all \(scoped.count)"))
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight)
                            .contentShape(Rectangle())
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func subtitle(_ e: HealthEvent) -> String {
        var parts = [EventFormat.dayAndTime(e.date)]
        if let hrv = e.recovery?.hrvReturn {
            parts.append(String(localized: "HRV \(EventFormat.share(hrv)) %"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: About

    private var aboutParagraphs: [String] {
        [
            String(localized: "Time to recover is how long your readings took to return toward their level before the event. HRV regained is how much of that level your HRV was back to, and Active again is how long after the event you were moving again."),
            String(localized: "Typical is the median of the events shown, so one slow recovery does not pull it far. Average is the mean."),
            String(localized: "Events of every kind are compared unless you pick one kind."),
        ]
    }
}
