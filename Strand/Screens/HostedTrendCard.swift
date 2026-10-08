import StrandDesign
import SwiftUI
import WhoopStore

/// Resolving a metric's trend points from banked days.
///
/// Extracted from `TrendsView` so the Today host cards resolve EXACTLY as the Trends tab does. It is
/// shared rather than copied on purpose: the widening fallback is the part a wearer with two weeks of
/// history actually depends on, and a second implementation of it would drift the moment either side
/// was tuned. `TrendsView.resolve` calls this too.
enum HostedTrendData {

    /// Day strings are banked as `yyyy-MM-dd` in UTC; parsing them any other way shifts every point.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The metric's points for the smallest window at or wider than `selected` that holds any data,
    /// and the window it settled on.
    ///
    /// Walks the widening order ONCE, keeping the window's points rather than re-filtering to read them
    /// back. Falls back to all history when no window held anything, which matches what the tab shows
    /// rather than leaving a new wearer with an empty card.
    static func resolve(days: [DailyMetric],
                        selected: TrendsView.Range,
                        value: (DailyMetric) -> Double?) -> (points: [TrendPoint], effective: TrendsView.Range) {
        for r in selected.widening {
            let pts = points(window(days, r), value)
            if !pts.isEmpty { return (pts, r) }
        }
        return (points(window(days, .all), value), .all)
    }

    /// The trailing window of `days`, anchored on today's local day exactly as the tab anchors it.
    private static func window(_ days: [DailyMetric], _ r: TrendsView.Range) -> [DailyMetric] {
        guard let n = r.days, n > 0 else { return days }
        let cutoff = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// The plotted y-range: the data's own span with a little air, the fixed fallback when there is no
    /// data at all, and a unit either side of a single repeated value so one flat line does not map onto
    /// a zero-width range.
    ///
    /// Shared with the tab for the same reason the windowing is. A card that padded by a different
    /// fraction would plot the SAME points at a visibly different height from the chart it mirrors,
    /// which is exactly the drift hosting is meant to avoid.
    static func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>,
                           pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private static func points(_ days: [DailyMetric], _ value: (DailyMetric) -> Double?) -> [TrendPoint] {
        days.compactMap { d in
            guard let v = value(d), let dt = dayParser.date(from: d.day) else { return nil }
            return TrendPoint(date: dt, value: v)
        }
    }
}

/// One Trends metric trend, rendered as a Today host card (#today-hosted-cards).
///
/// A miniature of the metric's own chart, from the same resolved points the Trends page draws: HRV and
/// resting HR as a line with gaps, Effort as score bars, in the kit's compact form with the scrub off (the
/// card is a link to the metric's detail page, so a drag must not compete with the tap).
///
/// What it does NOT carry is the range selector. A home-screen card has nowhere to put one and no place
/// to persist a per-card choice, so each takes a fixed trailing month and keeps the tab's widening
/// fallback for a wearer whose history is shorter than that. The Trends page stays where the window is
/// chosen. Twin of the Kotlin `TrendHostCard`.
struct HostedTrendCard: View {
    let card: HostedCard
    let days: [DailyMetric]
    /// The wearer's Effort scale, resolved by the host rather than read here: only one of the three
    /// cards needs it, and Today already has it for its own tiles.
    let effortScale: EffortScale

    var body: some View {
        switch card {
        case .trendHRV:
            chart(title: "Heart rate variability", spoken: String(localized: "Heart rate variability"), unit: "ms", colour: StrandPalette.metricPurple,
                  value: { $0.avgHrv }, minSpan: 20, fmt: { "\(Int($0.rounded()))" })
        case .trendRestingHR:
            chart(title: "Resting heart rate", spoken: String(localized: "Resting heart rate"), unit: "bpm", colour: StrandPalette.metricRose,
                  value: { $0.restingHr.map(Double.init) }, minSpan: 10, fmt: { "\(Int($0.rounded()))" })
        case .trendEffort:
            // Bars on the user's Effort scale (#268): the stored 0-100 value converted for the bars, the
            // axis and the average alike, so none of them disagree.
            chart(title: "Effort", spoken: String(localized: "Effort"), unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                  colour: StrandPalette.effortColor,
                  value: { d in d.strain.map { UnitFormatter.effortValue($0, scale: effortScale) } },
                  minSpan: 0, bars: true,
                  fmt: { effortScale == .whoop ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" })
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func chart(title: LocalizedStringKey, spoken: String, unit: String, colour: Color,
                       value: @escaping (DailyMetric) -> Double?, minSpan: Double, bars: Bool = false,
                       fmt: @escaping (Double) -> String) -> some View {
        let resolved = HostedTrendData.resolve(days: days, selected: .month, value: value)
        let range = resolved.effective.chartRange
        let points = resolved.points.map { DailyPoint($0, dayIsUTC: true) }
        let window = ChartAxis.window(range, firstDataDay: points.first?.day)
        let avg = points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
        // The average is labelled as one, with its window, so it never reads as today's value.
        let trailing = avg.map { String(localized: "\(range.days ?? points.count)-day avg \(fmt($0)) \(unit)") }
        let state: ChartState = points.isEmpty ? .empty(String(localized: "No history yet")) : .ready
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: NoopMetrics.space2)
                    if let trailing {
                        Text(trailing)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Group {
                    if bars {
                        let top = UnitFormatter.effortValue(100, scale: effortScale)
                        DailyBarChart.scores(points, ramp: { StrandPalette.effortTint(fraction: $0 / top) },
                                             scale: 0...top, meanLine: nil, state: state, window: window,
                                             xStyle: range.axisStyle, selection: .constant(nil),
                                             height: NoopMetrics.chartHeightCompact,
                                             accessibilityTitle: String(localized: "Effort"))
                    } else {
                        DailyLineChart(series: [.init(id: "trend", name: spoken,
                                                      color: colour, points: points)],
                                       state: state, window: window, xStyle: range.axisStyle,
                                       y: ChartValueAxis(unit: unit, domain: .fitted(minSpan: minSpan)),
                                       selection: .constant(nil), height: NoopMetrics.chartHeightCompact,
                                       accessibilityTitle: spoken)
                    }
                }
                .naraChartCompact()
                .naraChartScrubDisabled()
            }
        }
        .accessibilityElement(children: .combine)
        // The average goes into the spoken label, not just the visible corner. `children: .combine`
        // merges what the card renders, and overriding that with the bare title, as this first did,
        // silently drops the one number on the card.
        .accessibilityLabel(trailing.map { Text(title) + Text(verbatim: ", \($0)") } ?? Text(title))
    }
}
