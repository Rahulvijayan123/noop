#if DEBUG && !os(watchOS)
// Synthetic data for the chart previews only. Debug builds, never shipped.
import SwiftUI

/// The six states every kit chart preview shows: loading, empty, one point, three points, a month with gaps,
/// and a year. Values are deterministic so a preview looks the same on every run.
struct NaraChartPreviewSample {
    enum Kind: CaseIterable {
        case loading, empty, one, three, month, year

        var title: String {
            switch self {
            case .loading: return "Loading"
            case .empty: return "Empty"
            case .one: return "1 point"
            case .three: return "3 points"
            case .month: return "30 days with gaps"
            case .year: return "365 days"
            }
        }

        var intradayTitle: String {
            switch self {
            case .loading: return "Loading"
            case .empty: return "Empty"
            case .one: return "1 sample"
            case .three: return "3 samples"
            case .month: return "A day with gaps (5-minute buckets)"
            case .year: return "A dense day (1-minute samples)"
            }
        }
    }

    let kind: Kind
    let calendar = Calendar.current
    let now = Date()

    var range: ChartRange {
        switch kind {
        case .loading, .empty, .month: return .month
        case .one, .three: return .week
        case .year: return .year
        }
    }

    var state: ChartState {
        switch kind {
        case .loading: return .loading
        case .empty: return .empty("No readings in this range yet")
        default: return .ready
        }
    }

    /// Day offsets from today (0) that carry a value.
    var offsets: [Int] {
        switch kind {
        case .loading, .empty: return []
        case .one: return [0]
        case .three: return [-4, -2, 0]
        case .month:
            let gaps: Set<Int> = [-26, -25, -18, -11, -10, -9, -3]
            return (-29...0).filter { !gaps.contains($0) }
        case .year:
            let gaps = Set((-200)...(-188)).union([-90, -60, -59, -12])
            return (-364...0).filter { !gaps.contains($0) }
        }
    }

    var today: Date { calendar.startOfDay(for: now) }

    func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today).map { calendar.startOfDay(for: $0) } ?? today
    }

    var window: ClosedRange<Date> {
        ChartAxis.window(range, now: now, firstDataDay: offsets.first.map(day), calendar: calendar)
    }

    /// A deterministic wobble in -0.5...0.5.
    func jitter(_ i: Int) -> Double { Double((i * 37 + 11) % 17) / 17 - 0.5 }

    /// One value a day around `base`; `every` keeps one day in that many (sparse metrics) on the longer
    /// samples, and `estimateEvery` marks one point in that many as an estimate.
    func points(base: Double, swing: Double, every: Int = 1, estimateEvery: Int? = nil) -> [DailyPoint] {
        let kept = offsets.count > 3 ? offsets.filter { $0 % max(1, every) == 0 } : offsets
        return kept.enumerated().map { index, offset in
            let value = base + swing * sin(Double(offset) / 4) * 0.8 + swing * 0.4 * jitter(offset + 400)
            let estimate = estimateEvery.map { index % $0 == $0 - 1 } ?? false
            return DailyPoint(day: day(offset), value: value, isEstimate: estimate)
        }
    }

    /// A clock time today (only its time of day matters to the typical bands).
    func clock(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
    }

    /// Bedtime the evening before each day, wake on the day.
    func nights() -> [RangeBarChart.Item] {
        offsets.map { offset in
            let wakeDay = day(offset)
            let evening = day(offset - 1)
            let bed = evening.addingTimeInterval((22.5 + jitter(offset) * 2) * 3600)
            let wake = wakeDay.addingTimeInterval((6.75 + jitter(offset + 7) * 1.5) * 3600)
            return RangeBarChart.Item(day: wakeDay, start: bed, end: wake, isEstimate: offset % 9 == 0 && offset != 0)
        }
    }

    /// Stage minutes per night.
    func stages() -> [StackedBarChart.Day] {
        offsets.map { offset in
            StackedBarChart.Day(day: day(offset), values: [
                "deep": 75 + 25 * jitter(offset),
                "rem": 100 + 30 * jitter(offset + 3),
                "light": 230 + 40 * jitter(offset + 5),
            ])
        }
    }

    /// Today, midnight to midnight.
    var dayWindow: ClosedRange<Date> {
        today...(calendar.dateInterval(of: .day, for: now)?.end ?? today.addingTimeInterval(86_400))
    }

    /// Heart-rate buckets through the day for each sample kind.
    func heartRate() -> [IntradayChart.Sample] {
        func bpm(_ minute: Int) -> Double {
            let hour = Double(minute) / 60
            let asleep = hour < 7 ? -10.0 : 0
            return 64 + asleep + 14 * sin(hour / 3.5) + 6 * jitter(minute) + (hour > 17.5 && hour < 18.3 ? 70 : 0)
        }
        let start = dayWindow.lowerBound
        let minutes: [Int]
        switch kind {
        case .loading, .empty: return []
        case .one: minutes = [600]
        case .three: minutes = [600, 605, 640]
        case .month: minutes = stride(from: 0, to: 1440, by: 5).filter { !(780..<840).contains($0) && !(300..<330).contains($0) }
        case .year: minutes = Array(0..<1440).filter { !(780..<840).contains($0) }
        }
        return minutes.map { minute in
            IntradayChart.Sample(time: start.addingTimeInterval(Double(minute) * 60), value: bpm(minute))
        }
    }
}

enum NaraChartPreviewData {
    /// Illustrative bands for previews only; screens pass the scorer's own thresholds.
    static var chargeBands: ScoreBands {
        ScoreBands([
            .init(upperBound: 34, color: StrandPalette.metricRose, name: "Low"),
            .init(upperBound: 67, color: StrandPalette.metricAmber, name: "Medium"),
            .init(upperBound: .infinity, color: StrandPalette.chargeColor, name: "High"),
        ])
    }

    static var stageCategories: [StackedBarChart.Category] {
        [
            .init(id: "deep", name: "Deep", color: StrandPalette.sleepDeep),
            .init(id: "rem", name: "REM", color: StrandPalette.sleepREM),
            .init(id: "light", name: "Light", color: StrandPalette.sleepLight),
        ]
    }
}

/// Every sample kind in a card, one under the other, on the app canvas.
struct NaraChartPreviewGallery<Content: View>: View {
    private let title: String
    private let intraday: Bool
    private let content: (NaraChartPreviewSample) -> Content

    init(_ title: String, intraday: Bool = false, @ViewBuilder content: @escaping (NaraChartPreviewSample) -> Content) {
        self.title = title
        self.intraday = intraday
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                ForEach(NaraChartPreviewSample.Kind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Text(intraday ? kind.intradayTitle : kind.title)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        NoopCard {
                            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                                content(NaraChartPreviewSample(kind: kind))
                            }
                        }
                    }
                }
            }
            .padding(NoopMetrics.screenHPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}
#endif
