import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Alerts over three weeks
//
// Watchdog's alert ledger as floating bars: one column per calendar day of the 21 the ledger keeps, the
// time of day down the side (midnight at the top), each alert a bar from when it opened to when it closed,
// coloured by how strong it got. It answers what the list cannot: when in the day alerts cluster and how
// long they last. An alert across midnight is drawn as two bars, one on each day.
//
// Not a kit chart (kit_issues: a FloatingBarChart shared with sleep consistency); it uses the kit's axes,
// scrub, selection rule, legend and placeholders.

struct WatchdogAlertTimeline: View {
    struct Bar: Identifiable, Equatable {
        let id: String
        let episodeId: String
        /// Local start of the day the bar is drawn on.
        let day: Date
        /// Hours after that day's midnight, 0...24.
        let startHour: Double
        let endHour: Double
        let severity: String
    }

    let rows: [WatchdogEpisodeLedgerRow]
    let window: ClosedRange<Date>
    var state: ChartState = .ready
    @Binding var selection: Date?
    var height: CGFloat = NoopMetrics.chartHeightSecondary + 40

    /// The ledger's 21 days, ending today.
    static func window(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let end = calendar.dateInterval(of: .day, for: now)?.end ?? now
        let start = calendar.date(byAdding: .day, value: -21, to: end) ?? end
        return start...end
    }

    /// One bar per alert per day it touches. Pure, so the midnight split is tested
    /// (MonitorLabelsTests.testAlertBarsSplitAtMidnight).
    static func bars(_ rows: [WatchdogEpisodeLedgerRow], calendar: Calendar = .current) -> [Bar] {
        var out: [Bar] = []
        for row in rows {
            let open = Date(timeIntervalSince1970: TimeInterval(row.openedUnix))
            let close = Date(timeIntervalSince1970: TimeInterval(max(row.closedUnix ?? row.lastUnix, row.openedUnix)))
            var day = calendar.startOfDay(for: open)
            var part = 0
            while day <= close, part < 30 {
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
                let from = max(open, day)
                let to = min(close, next)
                let start = from.timeIntervalSince(day) / 3600
                let end = max(start, to.timeIntervalSince(day) / 3600)
                if to > from || part == 0 {
                    out.append(Bar(id: "\(row.episodeId)-\(part)", episodeId: row.episodeId, day: day,
                                   startHour: start, endHour: min(24, end), severity: row.maxSeverity))
                }
                part += 1
                day = next
            }
        }
        return out.sorted { ($0.day, $0.startHour) < ($1.day, $1.startHour) }
    }

    static func color(_ severity: String) -> Color {
        WatchdogEventCopy.tone(severity)
    }

    private var bars: [Bar] { Self.bars(rows).filter { window.contains($0.day) } }
    private var days: [Date] { Array(Set(bars.map(\.day))).sorted() }

    private var legend: [ChartLegendItem] {
        var items: [ChartLegendItem] = []
        if bars.contains(where: { $0.severity == "candidate" }) {
            items.append(ChartLegendItem(.swatch(Self.color("candidate")), "Watching"))
        }
        if bars.contains(where: { $0.severity != "candidate" }) {
            items.append(ChartLegendItem(.swatch(Self.color("active")), "Alert"))
        }
        return items
    }

    private var yLayout: ChartYAxisLayout {
        let ticks: [Double] = [0, -6, -12, -18, -24]
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        let labels = ticks.map { tick -> String in
            guard tick > -24 else { return "" }
            let date = midnight.addingTimeInterval(-tick * 3600)
            return date.formatted(.dateTime.hour())
        }
        return ChartYAxisLayout(domain: -24...0, ticks: ticks, labels: labels, unit: nil)
    }

    var body: some View {
        let showsLegend = true
        let plotHeight = max(0, height - (showsLegend ? NaraChartStyle.legendHeight + NaraChartStyle.legendSpacing : 0))
        VStack(alignment: .leading, spacing: NaraChartStyle.legendSpacing) {
            switch state {
            case .loading:
                ChartPlaceholder(height: plotHeight)
            case .empty(let message):
                EmptyChartMessage(message, height: plotHeight)
            case .ready:
                if bars.isEmpty {
                    EmptyChartMessage("No alerts in the last 21 days", height: plotHeight)
                } else {
                    chart(plotHeight: plotHeight).frame(height: plotHeight)
                }
            }
            if state == .ready, !bars.isEmpty {
                ChartLegend(legend)
            } else {
                Color.clear.frame(height: NaraChartStyle.legendHeight)
            }
        }
        .frame(height: height)
    }

    private func chart(plotHeight: CGFloat) -> some View {
        let selectedDay = selection.map { Calendar.current.startOfDay(for: $0) }
        // A five-minute alert would be a hairline on a 24-hour axis: every bar is at least 6 pt tall.
        let minHours = 24 * 6 / max(plotHeight, 1)
        return Chart {
            SelectionRule(selectedDay, unit: .day)
            ForEach(bars) { bar in
                let end = max(bar.endHour, min(24, bar.startHour + minHours))
                BarMark(x: .value("Day", bar.day, unit: .day),
                        yStart: .value("Opened", -bar.startHour),
                        yEnd: .value("Closed", -end),
                        width: .ratio(NaraChartStyle.rangeBarWidthRatio))
                    .foregroundStyle(Self.color(bar.severity))
                    .cornerRadius(NaraChartStyle.barCornerRadius)
                    .opacity(selectedDay == nil || selectedDay == bar.day ? 1 : NaraChartStyle.dimmedOpacity)
            }
        }
        .naraChartAxes(x: ChartAxis.layout(window, style: .dayOfMonth), y: yLayout)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: days, selection: $selection)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Alerts"))
        .accessibilityValue(Text("\(rows.count) in the last 21 days"))
    }
}
