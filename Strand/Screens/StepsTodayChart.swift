import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// Today's steps on the key-metric Steps screen: the running total since local midnight, drawn through the day so
/// the reader sees when the steps came (a flat stretch is a stretch without any) and not one number. The strap's
/// step counter is read in 15-minute slices (`KeyMetricReadings.cumulativeSteps`), counted with the same kernel as
/// the day total. Touch or drag to read the total at a moment and what was added in the slice before it.
struct StepsTodayChart: View {
    enum Kind { case steps, calories }
    var kind: Kind = .steps
    /// The Calories headline's figure so far today; the running total ends on it.
    var dayTotal: Double?

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var points: [KeyMetricReadings.CumulativePoint]?
    @State private var loaded = false
    @State private var selected: Date?

    private static let slice = 900

    private var dayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var domain: ClosedRange<Date> { dayStart...max(dayStart.addingTimeInterval(3_600), Date()) }

    private var emptyText: String {
        switch kind {
        case .steps:
            return loaded ? String(localized: "No steps counted by your strap yet today.")
                : String(localized: "Reading your strap's steps…")
        case .calories:
            return loaded ? String(localized: "No heart rate recorded yet today, so there is no energy to chart.")
                : String(localized: "Estimating today's energy from your heart rate…")
        }
    }

    private var series: [(date: Date, steps: Double)] {
        let start = dayStart
        return [(date: start, steps: 0)] + (points ?? []).map { (date: Date(timeIntervalSince1970: TimeInterval($0.ts)), steps: $0.steps) }
    }

    /// The point nearest the finger, or the newest.
    private var pick: (date: Date, steps: Double)? {
        let all = series
        guard let selected else { return all.last }
        return all.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    var body: some View {
        KeyMetricPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "Today"))
                        .font(KeyMetricStyle.labelStrong)
                        .foregroundStyle(KeyMetricStyle.text)
                    Spacer(minLength: 8)
                    Text(kind == .steps ? String(localized: "Running total, every 15 minutes") : String(localized: "Running total, estimated from heart rate"))
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                }
                if let points, !points.isEmpty {
                    chart
                    Text(readout)
                        .font(KeyMetricStyle.label)
                        .foregroundStyle(KeyMetricStyle.text)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(emptyText)
                        .font(KeyMetricStyle.label)
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                }
            }
        }
        .task(id: "\(repo.refreshSeq)|\(Repository.localDayKey(Date()))|\(profile.stepTicksPerStep)|\(Int(dayTotal ?? 0))") { await load() }
    }

    private var chart: some View {
        let domain = self.domain
        return Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Time", p.date), y: .value("Steps", p.steps))
                    .foregroundStyle(LinearGradient(colors: [KeyMetricStyle.accent.opacity(0.35), KeyMetricStyle.accent.opacity(0.03)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Steps", p.steps))
                    .foregroundStyle(KeyMetricStyle.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let pick {
                RuleMark(x: .value("Time", pick.date))
                    .foregroundStyle(KeyMetricStyle.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", pick.date), y: .value("Steps", pick.steps))
                    .foregroundStyle(KeyMetricStyle.accent)
                    .symbolSize(70)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(100, (series.last?.steps ?? 0) * 1.1))
        .chartXAxis {
            AxisMarks(values: ticks(domain)) { value in
                AxisGridLine().foregroundStyle(KeyMetricStyle.border)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(KeyMetricDetailView.hourLabel(date, zone: .current))
                            .font(KeyMetricStyle.small)
                            .foregroundStyle(KeyMetricStyle.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(KeyMetricStyle.border)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Int(v).formatted(.number))
                            .font(KeyMetricStyle.small)
                            .foregroundStyle(KeyMetricStyle.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                touchSurface(proxy: proxy, plot: plot)
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
            }
        }
        .frame(height: 190)
        .accessibilityLabel(Text(kind == .steps ? String(localized: "Steps through today") : String(localized: "Calories through today")))
    }

    @ViewBuilder
    private func touchSurface(proxy: ChartProxy, plot: CGRect) -> some View {
        #if os(iOS)
        HorizontalScrubSurface(onScrub: { select($0, proxy: proxy, plot: plot) }, onEnd: {},
                               onTap: { select($0, proxy: proxy, plot: plot) })
        #else
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { select($0.location.x, proxy: proxy, plot: plot) })
        #endif
    }

    /// `x` is in the touch surface's own space, which starts at the plot's leading edge.
    private func select(_ x: CGFloat, proxy: ChartProxy, plot: CGRect) {
        guard plot.width > 0, let date: Date = proxy.value(atX: min(max(x, 0), plot.width)) else { return }
        if pick.map({ abs($0.date.timeIntervalSince(date)) > 450 }) ?? true { StrandHaptic.selection.play() }
        selected = date
    }

    private func ticks(_ domain: ClosedRange<Date>) -> [Date] {
        KeyMetricDetailView.hourTicks(domain, zone: .current)
    }

    private var readout: String {
        guard let pick else { return " " }
        let all = series
        let total = Int(pick.steps.rounded())
        let time = KeyMetricDetailView.timeText(pick.date, zone: .current)
        let noun = kind == .steps ? String(localized: "steps") : String(localized: "kcal")
        var line = String(localized: "\(total.formatted(.number)) \(noun) by \(time)")
        if let i = all.firstIndex(where: { $0.date == pick.date }), i > 0 {
            let added = Int((pick.steps - all[i - 1].steps).rounded())
            if added > 0 { line += " · " + String(localized: "+\(added.formatted(.number)) \(noun) in the 15 minutes before") }
        }
        return line
    }

    private func load() async {
        let from = Int(dayStart.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let result: [KeyMetricReadings.CumulativePoint]?
        switch kind {
        case .steps:
            result = await repo.stepsThroughDay(from: from, to: to, ticksPerStep: profile.stepTicksPerStep)
        case .calories:
            let user = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                                   age: Double(profile.age), sex: profile.sex)
            let resting = repo.days.last { $0.restingHr != nil }?.restingHr.map(Double.init)
            result = await repo.caloriesThroughDay(from: from, to: to, profile: user, hrmax: Double(profile.hrMax),
                                                   restingHR: resting, dayTotal: dayTotal)
        }
        guard !Task.isCancelled else { return }
        points = result
        loaded = true
    }
}
