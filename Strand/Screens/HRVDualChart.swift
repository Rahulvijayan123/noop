import SwiftUI
import Charts
import StrandDesign

/// One night's two HRV numbers. Either may be missing: a night scored before the SDNN index existed
/// still plots its RMSSD, and an Apple-only night can carry SDNN alone.
struct HRVDualPoint: Identifiable, Equatable {
    let day: String
    let date: Date
    let rmssd: Double?
    let sdnn: Double?
    var id: String { day }
}

enum HRVDualSeries {
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { dayParser.date(from: day) }

    /// Joins the two series on day. RMSSD and SDNN stay in separate fields; they are different
    /// statistics and are never blended into one number.
    static func merge(
        rmssd: [(day: String, value: Double)],
        sdnn: [(day: String, value: Double)]
    ) -> [HRVDualPoint] {
        var byDay: [String: (rmssd: Double?, sdnn: Double?)] = [:]
        for r in rmssd where r.value.isFinite && r.value > 0 { byDay[r.day, default: (nil, nil)].rmssd = r.value }
        for s in sdnn where s.value.isFinite && s.value > 0 { byDay[s.day, default: (nil, nil)].sdnn = s.value }
        return byDay.keys.sorted().compactMap { day in
            guard let date = date(day), let pair = byDay[day] else { return nil }
            return HRVDualPoint(day: day, date: date, rmssd: pair.rmssd, sdnn: pair.sdnn)
        }
    }

    /// SDNN readings that fall inside the RMSSD window the screen is showing.
    static func window(
        _ series: [(day: String, value: Double)],
        firstDay: String?
    ) -> [(day: String, value: Double)] {
        guard let firstDay else { return series }
        return series.filter { $0.day >= firstDay }
    }

    /// Run ids that advance wherever more than `maxGapDays` separate two readings, so the line is not
    /// drawn across nights that were never measured.
    static func segmentIDs(dates: [Date], maxGapDays: Int = 3) -> [Int] {
        var ids: [Int] = []
        var current = 0
        var previous: Date?
        for d in dates {
            if let previous, d.timeIntervalSince(previous) > Double(maxGapDays) * 86_400 { current += 1 }
            ids.append(current)
            previous = d
        }
        return ids
    }

    /// Mean SDNN ÷ mean RMSSD over nights that have both numbers.
    static func ratio(_ points: [HRVDualPoint]) -> Double? {
        let both = points.compactMap { p -> (Double, Double)? in
            guard let r = p.rmssd, let s = p.sdnn else { return nil }
            return (r, s)
        }
        guard !both.isEmpty else { return nil }
        let meanR = both.map(\.0).reduce(0, +) / Double(both.count)
        let meanS = both.map(\.1).reduce(0, +) / Double(both.count)
        return meanR > 0 ? meanS / meanR : nil
    }
}

struct HRVDualChart: View {
    let points: [HRVDualPoint]
    var baselineRMSSD: Double?
    var height: CGFloat = NoopMetrics.chartHeight

    @State private var selectedDay: String?

    static let rmssdName = "RMSSD"
    static let sdnnName = "SDNN"
    static var rmssdColor: Color { StrandPalette.metricPurple }
    static var sdnnColor: Color { StrandPalette.metricCyan }

    private struct Mark: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let name: String
        let run: String
    }

    private var marks: [Mark] {
        func build(_ name: String, _ pick: (HRVDualPoint) -> Double?) -> [Mark] {
            let present = points.compactMap { p in pick(p).map { (point: p, value: $0) } }
            let runs = HRVDualSeries.segmentIDs(dates: present.map { $0.point.date })
            return zip(present, runs).map { item, run in
                Mark(id: "\(name)-\(item.point.day)", date: item.point.date, value: item.value,
                     name: name, run: "\(name)-\(run)")
            }
        }
        return build(Self.rmssdName) { $0.rmssd } + build(Self.sdnnName) { $0.sdnn }
    }

    private var yDomain: ClosedRange<Double> {
        var values = points.flatMap { [$0.rmssd, $0.sdnn].compactMap { $0 } }
        if let baselineRMSSD { values.append(baselineRMSSD) }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let pad = max((hi - lo) * 0.15, 4)
        return max(0, lo - pad)...(hi + pad)
    }

    private var selected: HRVDualPoint? {
        guard let selectedDay else { return nil }
        return points.first { $0.day == selectedDay }
    }

    private var showsDots: Bool { points.count <= 45 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            readout
            chart
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var readout: some View {
        let shown = selected ?? points.last
        return HStack(spacing: 14) {
            legendItem(Self.rmssdName, color: Self.rmssdColor, value: shown?.rmssd)
            legendItem(Self.sdnnName, color: Self.sdnnColor, value: shown?.sdnn)
            Spacer(minLength: 0)
            if let shown {
                Text(Self.dayLabel(shown.date))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(minHeight: 22)
    }

    private func legendItem(_ name: String, color: Color, value: Double?) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(name)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value.map { "\(Int($0.rounded())) ms" } ?? "no data")
                .font(StrandFont.captionNumber)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
    }

    private var chart: some View {
        Chart {
            if let baselineRMSSD {
                RuleMark(y: .value("RMSSD baseline", baselineRMSSD))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Self.rmssdColor.opacity(0.4))
            }
            ForEach(marks) { m in
                LineMark(
                    x: .value("Day", m.date),
                    y: .value("ms", m.value),
                    series: .value("Run", m.run)
                )
                .foregroundStyle(by: .value("Metric", m.name))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))

                PointMark(x: .value("Day", m.date), y: .value("ms", m.value))
                    .foregroundStyle(by: .value("Metric", m.name))
                    .symbolSize(showsDots ? 30 : 0)
            }
            if let selected {
                RuleMark(x: .value("Day", selected.date))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale([
            Self.rmssdName: Self.rmssdColor,
            Self.sdnnName: Self.sdnnColor,
        ])
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.5))
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(Self.axisLabel(date)).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.5))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    // Press-and-hold before dragging, so a plain swipe on the chart still scrolls the page.
                    .gesture(
                        LongPressGesture(minimumDuration: 0.15)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { state in
                                if case .second(true, let drag?) = state {
                                    select(x: drag.location.x, proxy: proxy, plot: plot)
                                }
                            }
                            .onEnded { _ in selectedDay = nil }
                    )
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location): select(x: location.x, proxy: proxy, plot: plot)
                        case .ended: selectedDay = nil
                        }
                    }
            }
        }
        .frame(height: height)
    }

    private func select(x: CGFloat, proxy: ChartProxy, plot: CGRect) {
        guard plot.width > 0 else { return }
        let clamped = min(max(x, plot.minX), plot.maxX)
        guard let date: Date = proxy.value(atX: clamped - plot.minX) else { return }
        let nearest = points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        if nearest?.day != selectedDay { selectedDay = nearest?.day }
    }

    private var accessibilitySummary: String {
        guard let last = points.last else { return "Heart rate variability chart, no data" }
        let r = last.rmssd.map { "RMSSD \(Int($0.rounded())) milliseconds" } ?? "no RMSSD"
        let s = last.sdnn.map { "SDNN \(Int($0.rounded())) milliseconds" } ?? "no SDNN"
        return "Heart rate variability, \(points.count) nights. Latest \(r), \(s)."
    }

    // Days are UTC calendar dates, so format in UTC or a US timezone would show the previous day.
    private static func dayLabel(_ date: Date) -> String { format(date, template: "EEEMMMd") }

    private static func axisLabel(_ date: Date) -> String { format(date, template: "MMMd") }

    private static func format(_ date: Date, template: String) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
