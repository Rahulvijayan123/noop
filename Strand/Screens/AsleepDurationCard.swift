import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// MARK: - Asleep duration trend (#today-hosted-cards)
//
// The Sleep tab's "Asleep duration" card, extracted into a standalone view so it can ALSO be hosted in
// the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `AsleepDurationData`,
// so the number can never diverge between the two surfaces (the parity contract). The card body is a
// verbatim lift of the former `SleepView.durationTrend`; the data builder is a verbatim lift of
// `SleepView.durationTrendPoints` + `typicalTotalMin`.

/// Pure inputs for the asleep-duration card: trailing-30-night sleep hours + the typical mean minutes.
/// Built identically by the Sleep tab and by a Today host so the two never diverge.
struct AsleepDurationData {
    let points: [TrendPoint]
    let typicalTotalMin: Double?

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC) — matches `SleepView.dayParser`.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Trailing 30 days of total sleep in HOURS, falling back to all nights with data when the trailing
    /// window is too sparse (verbatim of `SleepView.durationTrendPoints`). `typicalTotalMin` is the mean
    /// asleep minutes across nights with data (verbatim of `SleepView.typicalTotalMin`).
    static func build(days: [DailyMetric]) -> AsleepDurationData {
        func mk(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = dayParser.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = mk(days.suffix(30))
        let points = recent.count >= 2 ? recent : mk(days[...])
        let totals = days.compactMap { $0.totalSleepMin }.filter { $0 > 0 }
        let typical = totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
        return AsleepDurationData(points: points, typicalTotalMin: typical)
    }
}

/// The "Asleep duration" trend card. Renders [AsleepDurationData] with the shared chart components.
struct AsleepDurationCard: View {
    let data: AsleepDurationData

    var body: some View {
        let pts = data.points
        let avg = data.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend")
            ChartCard(
                title: "Hours asleep",
                subtitle: String(localized: "One bar per night · dashed line is your average"),
                trailing: avg.map { String(localized: "\(String(format: "%.1f", $0)) h avg") },
                height: NoopMetrics.chartHeight,
                tint: StrandPalette.restColor,
                chart: {
                    if pts.count >= 2 {
                        AsleepDurationBars(points: pts, average: avg)
                            .frame(height: NoopMetrics.chartHeight)
                    } else {
                        Self.sparsePlaceholder
                    }
                },
                footer: {
                    HStack {
                        ChartFooter([
                            ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                            ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                            ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                            ("Nights", "\(pts.count)"),
                        ])
                        durationTrendStat(pts)
                    }
                }
            )
        }
    }

    /// A padded value range so the line isn't flat against the axis (verbatim of `SleepView.trendRange`).
    private static func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }

    private static var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
    }

    /// Recent-half mean minus earlier-half mean (verbatim of `SleepView.durationTrendChange`). Direction
    /// is neutral: more sleep isn't automatically better, so the chip conveys movement without a verdict.
    private static func durationTrendChange(_ points: [TrendPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let midpoint = points.count / 2
        let earlier = points.prefix(midpoint).map(\.value)
        let recent = points.suffix(points.count - midpoint).map(\.value)
        guard !earlier.isEmpty, !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
            - earlier.reduce(0, +) / Double(earlier.count)
    }

    @ViewBuilder
    private func durationTrendStat(_ points: [TrendPoint]) -> some View {
        let delta = Self.durationTrendChange(points)
        let deltaText = delta.map {
            let sign = $0 >= 0 ? "+" : "−"
            return "\(sign)\(String(format: "%.1f h", abs($0)))"
        }
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text("Trend")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            if let deltaText {
                TrendChip(text: deltaText, color: StrandPalette.textTertiary)
            } else {
                Text("—")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(String(localized: "Trend")): \(deltaText ?? "—")"))
    }
}

/// One bar per night, labelled with its weekday and date and its hours, so the chart reads without
/// tapping. Nights are categories keyed by their calendar day (never positioned on a time axis), so a
/// night can't slide a day under a timezone change; the trend dates are UTC-parsed day keys.
private struct AsleepDurationBars: View {
    let points: [TrendPoint]
    let average: Double?

    private static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .current

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = utc
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let keyFormat = formatter("yyyyMMdd")
    private static let weekdayFormat = formatter("EEE")
    private static let dayFormat = formatter("MMMd")

    private var keys: [String] { points.map { Self.keyFormat.string(from: $0.date) } }
    private var showsValues: Bool { points.count <= 8 }

    private var labelledKeys: [String] {
        let all = keys
        guard all.count > 8 else { return all }
        let step = Int((Double(all.count) / 6).rounded(.up))
        return all.enumerated().filter { $0.offset % step == 0 || $0.offset == all.count - 1 }.map(\.element)
    }

    private var yMax: Double {
        let top = (points.map(\.value).max() ?? 8)
        return Swift.max(4, (top / 2).rounded(.up) * 2 + (showsValues ? 1 : 0))
    }

    var body: some View {
        let keys = self.keys
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                BarMark(x: .value("Night", keys[i]), y: .value("Hours asleep", p.value), width: .ratio(0.62))
                    .foregroundStyle(LinearGradient(gradient: StrandPalette.restGradient,
                                                    startPoint: .bottom, endPoint: .top))
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 3) {
                        if showsValues {
                            Text(String(format: "%.1f", p.value))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: 2)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let h = value.as(Double.self) {
                        Text("\(Int(h))h").font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: labelledKeys) { value in
                AxisValueLabel(centered: true) {
                    if let key = value.as(String.self), let date = Self.keyFormat.date(from: key) {
                        VStack(spacing: 1) {
                            Text(Self.weekdayFormat.string(from: date))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Text(Self.dayFormat.string(from: date))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Hours asleep per night"))
    }
}
