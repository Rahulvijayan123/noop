import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Asleep duration trend (#today-hosted-cards)
//
// The asleep-per-night card Today hosts. It renders `AsleepDurationData`, built by the same pure builder
// the Sleep model uses (`SleepModel.durationTrendPoints`), so the hosted copy and the Sleep tab never
// disagree about a night. Drawn with the Sleep tab's own `AsleepNightsChart`: bars in hours from zero
// against the sleep need (the same normative need the sleep-debt surfaces use), missing nights as gaps.

/// Pure inputs for the asleep-duration card: trailing-30-night sleep hours, the typical mean minutes and
/// the sleep need. Built identically by the Sleep tab and by a Today host so the two never diverge.
struct AsleepDurationData {
    let points: [TrendPoint]
    let typicalTotalMin: Double?
    /// The normative per-user need (`SleepModel.debtNeedMin`) the need rule is drawn at; nil draws none.
    var needMin: Double? = nil

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
        return AsleepDurationData(points: points, typicalTotalMin: typical,
                                  needMin: days.isEmpty ? nil : SleepModel.debtNeedMin(days: days))
    }

    /// The points as local-day chart points in MINUTES (the trend points are UTC midnights in hours).
    var chartPoints: [DailyPoint] {
        points.map { DailyPoint(day: ChartDay.day(fromUTCMidnight: $0.date), value: $0.value * 60) }
    }
}

/// The "Asleep duration" card: the last 30 nights against the need.
struct AsleepDurationCard: View {
    let data: AsleepDurationData

    private static let nights = 30

    var body: some View {
        let points = data.chartPoints
        let window = AsleepNightsChart.window(nights: Self.nights)
        let shown = points.filter { window.contains($0.day) }.map(\.value)
        let average = shown.isEmpty ? nil : shown.reduce(0, +) / Double(shown.count)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration",
                          trailing: average.map { String(localized: "avg \(SleepFormat.duration($0))") })
            NoopCard {
                AsleepNightsChart(points: points, needMin: data.needMin, nights: Self.nights,
                                  height: NoopMetrics.chartHeightSecondary)
            }
        }
    }
}
