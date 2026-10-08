import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Sleep tab cards
//
// The pieces the Sleep tab's root is built from, each at one fixed height so loading, an empty night and
// a full night all lay out the same.

/// The night summary: the Rest ring with its state word, then asleep against the need, the in-bed window
/// and efficiency. A nil score keeps the ring, with "—".
struct NightSummaryLayout: View {
    let score: Double?
    let asleep: String?
    let need: String?
    let window: String?
    let efficiency: String?
    var isLoading: Bool = false

    static let ringDiameter: CGFloat = 104

    var body: some View {
        NoopCard {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                VStack(spacing: NoopMetrics.space2) {
                    ScoreRing(fraction: score.map { $0 / 100 }, value: SleepFormat.score(score) ?? "—",
                              color: StrandPalette.restColor, diameter: Self.ringDiameter, isLoading: isLoading)
                    // Reserved when there is no score, so the card is the same height either way.
                    Text(score.map(SleepFormat.restWord) ?? " ")
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(score.map {
                    String(localized: "Sleep performance \(Int($0.rounded())) of 100, \(SleepFormat.restWord($0))")
                } ?? String(localized: "Rest, no score")))

                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    fact("Asleep", value: asleep, detail: need)
                    fact("In bed", value: window)
                    fact("Efficiency", value: efficiency, unit: "%")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .loadingPlaceholder(isLoading)
    }

    private func fact(_ label: LocalizedStringKey, value: String?, unit: String? = nil,
                      detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(value ?? "—")
                    .font(StrandFont.number(18))
                    .foregroundStyle(StrandPalette.textPrimary)
                if value != nil, let unit {
                    Text(unit)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if value != nil, let detail {
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Trends grid: sleep debt, consistency, restorative share and respiratory rate. Each tile opens its
/// OWN metric page (one link per tile). `model: nil` draws the loading layout.
struct SleepTrendTiles: View {
    let model: SleepModel?

    private let columns = [GridItem(.flexible(), spacing: NoopMetrics.gap),
                           GridItem(.flexible(), spacing: NoopMetrics.gap)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: NoopMetrics.gap) {
            tile(key: "sleep_debt_min", icon: "hourglass", color: StrandPalette.restColor, label: "Sleep debt",
                 value: model?.sleepDebt.latest.map { SleepFormat.duration($0) }, unit: nil,
                 state: model.flatMap { debtState($0.sleepDebt.latest) }, tone: nightDetailDebtTone(model?.sleepDebt.latest),
                 trend: model?.sleepDebt.series)
            tile(key: "sleep_consistency", icon: "calendar", color: StrandPalette.restColor, label: "Consistency",
                 value: model?.consistency.latest.map(Self.whole), unit: "%",
                 state: model.flatMap { SleepTileCaption.state($0.consistency, unit: "%") }, tone: .neutral,
                 trend: model?.consistency.series, opensDetail: false)
            tile(key: "restorative_pct", icon: "sparkles", color: StrandPalette.sleepREM, label: "Restorative",
                 value: model?.restorative.latest.map(Self.whole), unit: "%",
                 state: model.flatMap { SleepTileCaption.state($0.restorative, unit: "%") }, tone: .neutral,
                 trend: model?.restorative.series)
            tile(key: "resp_rate", icon: "lungs", color: StrandPalette.metricPurple, label: "Respiratory",
                 value: model?.respiratory.latest.map { String(format: "%.1f", $0) }, unit: "rpm",
                 state: model.flatMap { SleepTileCaption.state($0.respiratory, unit: "rpm", decimals: 1) }, tone: .neutral,
                 trend: model?.respiratory.series)
        }
    }

    @ViewBuilder
    private func tile(key: String, icon: String, color: Color, label: LocalizedStringKey, value: String?,
                      unit: String?, state: String?, tone: StrandTone, trend: [Double]?,
                      opensDetail: Bool = true) -> some View {
        let metricTile = MetricTile(icon: icon, iconColor: color, label: label, value: value, unit: unit,
                                    state: state, stateTone: tone, trend: trend.map { Array($0.suffix(14)) },
                                    reservesTrendSlot: true, isLoading: model == nil)
        // Consistency is computed from the nights on this device, but its metric page only fills from a WHOOP
        // export, so it is not a link: a number that opens an empty page is worse than a number that does not open.
        if model != nil, opensDetail {
            SleepRouteLink(route: .metricSourced(key: key, source: "my-whoop")) { metricTile }
                .buttonStyle(StrandPressableButtonStyle())
        } else {
            metricTile
        }
    }

    private static func whole(_ v: Double) -> String { "\(Int(v.rounded()))" }

    /// "On target" / "Below need" (the tested `nightDetailDebtCaption`), or nothing without a value.
    private func debtState(_ debt: Double?) -> String? {
        debt == nil ? nil : nightDetailDebtCaption(debt)
    }
}

/// The state line a Sleep metric tile carries: "Carried · 12 Jul" when the value is a prior night's
/// (#1946, `SleepModel.carriedMetricCaption`), else the latest against the typical mean ("+2% vs typical",
/// "Typical" when it rounds to no difference), else nothing.
enum SleepTileCaption {
    static func state(_ metric: SleepModel.Metric, unit: String, decimals: Int = 0) -> String? {
        if let carried = SleepModel.carriedMetricCaption(latestDay: metric.latestDay, latest: metric.latest) {
            return carried
        }
        guard let latest = metric.latest, let typical = metric.typical, typical != 0 else { return nil }
        let diff = latest - typical
        let mag = abs(diff)
        let rounded = decimals == 0 ? mag.rounded() : (mag * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        if rounded == 0 { return String(localized: "Typical") }
        let sign = diff >= 0 ? "+" : "−"
        let num = decimals == 0 ? "\(Int(rounded))" : String(format: "%.\(decimals)f", rounded)
        let suffix = unit == "%" ? "%" : " \(unit)"
        return String(localized: "\(sign)\(num)\(suffix) vs typical")
    }
}

// MARK: - Asleep, night by night

/// Asleep time per night against the sleep need: bars in hours from zero, the need as a labelled rule,
/// missing nights as gaps. Used by the Sleep tab (the last 14 nights) and by Today's hosted card.
struct AsleepNightsChart: View {
    /// One point per wake day, minutes asleep.
    let points: [DailyPoint]
    let needMin: Double?
    let nights: Int
    var state: ChartState = .ready
    var height: CGFloat = NoopMetrics.chartHeightSecondary

    var body: some View {
        DailyBarChart.totals(points, color: StrandPalette.restColor,
                             goal: needMin.map { ChartReference($0, label: String(localized: "Need \(SleepFormat.duration($0))")) },
                             bin: .day, state: effectiveState, window: Self.window(nights: nights),
                             xStyle: nights <= 7 ? .weekday : .dayOfMonth,
                             y: .durationMinutes(), selection: .constant(nil), height: height,
                             accessibilityTitle: String(localized: "Asleep"))
            .naraChartScrubDisabled()
    }

    private var effectiveState: ChartState {
        if case .ready = state, points.isEmpty { return .empty(String(localized: "No nights yet")) }
        return state
    }

    /// The `nights` local days ending today.
    static func window(nights: Int, now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let start = calendar.date(byAdding: .day, value: -(max(1, nights) - 1), to: today.start) ?? today.start
        return calendar.startOfDay(for: start)...today.end
    }

    /// Asleep minutes per stored day key (local days), dropping days with none.
    static func points(days: [DailyMetric]) -> [DailyPoint] {
        days.compactMap { d in
            guard let m = d.totalSleepMin, m > 0 else { return nil }
            return DailyPoint(key: d.day, value: m)
        }
    }
}

/// The Sleep tab's asleep card: the last 14 nights with their average, opening the asleep-time page.
struct AsleepNightsCard: View {
    let days: [DailyMetric]
    let needMin: Double?
    let state: ChartState

    private static let nights = 14

    var body: some View {
        let points = AsleepNightsChart.points(days: days)
        let window = AsleepNightsChart.window(nights: Self.nights)
        let recent = points.filter { window.contains($0.day) }.map(\.value)
        let average = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text("Asleep")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(average.map { String(localized: "\(Self.nights)-night avg \(SleepFormat.duration($0))") } ?? " ")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                AsleepNightsChart(points: points, needMin: needMin, nights: Self.nights, state: state)
            }
        }
    }
}
