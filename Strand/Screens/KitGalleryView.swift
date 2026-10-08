#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Kit gallery (DEBUG only)
//
// Every kit chart and component on synthetic data, in every state a screen can put it in, so the kit can be
// checked in a simulator before screens adopt it:
//
//   --demo-screen kitcharts        every chart type: loading, empty, 1 point, 3 points, 30 days with gaps
//                                  (missing days and a missing week), 365 days, estimates, references,
//                                  bands and means; add `--demo-chart-select 0.7` for the scrubbed state
//   --demo-screen kitcomponents    rings, readouts, stat grids, tiles, About, lists, readings, stepper,
//                                  section headers, range controls and the small pieces
//   --demo-kit-only charge,steps   only the named sections (ids in `KitGallery.chartSections` /
//                                  `componentSections`), for a short tour while iterating
//
// Each case prints its measured height beside its title, so a placeholder or empty frame that is not the
// height of the ready chart, or a readout that grows, shows up in the screenshot as a number. Nothing here
// reads the app's data; the values are deterministic functions of the day offset.

enum KitGallery {
    static let chartSections = ["charge", "hrv", "spo2", "skintemp", "schedule", "stages", "mood", "weight",
                                "vo2", "steps", "intraday"]
    static let componentSections = ["rings", "readout", "stats", "tiles", "about", "lists", "readings",
                                    "stepper", "headers", "ranges", "small"]

    /// `--demo-kit-only a,b`: the sections to draw; nil draws them all.
    static let only: Set<String>? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-kit-only"), i + 1 < args.count else { return nil }
        return Set(args[i + 1].lowercased().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }()

    static func shows(_ id: String) -> Bool { only?.contains(id) ?? true }
}

// MARK: - Synthetic data

/// The sample states every chart section draws.
enum KitSample: CaseIterable {
    case loading, empty, one, three, month, year

    var title: String {
        switch self {
        case .loading: return "Loading"
        case .empty: return "Empty"
        case .one: return "1 point · W"
        case .three: return "3 points · W"
        case .month: return "30 days with gaps (2 days, a week, 1 day) · M"
        case .year: return "365 days with gaps · Y (bar charts bin monthly)"
        }
    }

    var range: ChartRange {
        switch self {
        case .loading, .empty, .month: return .month
        case .one, .three: return .week
        case .year: return .year
        }
    }

    func state(_ emptyText: String) -> ChartState {
        switch self {
        case .loading: return .loading
        case .empty: return .empty(emptyText)
        default: return .ready
        }
    }

    /// Day offsets from today (0) that carry a value. The month misses two days, a whole week and one
    /// day; the year misses three weeks, a week and a few single days.
    var offsets: [Int] {
        switch self {
        case .loading, .empty: return []
        case .one: return [0]
        case .three: return [-5, -2, 0]
        case .month:
            let gaps = Set([-26, -25, -3]).union(-18...(-12))
            return (-29...0).filter { !gaps.contains($0) }
        case .year:
            let gaps = Set((-300)...(-280)).union((-200)...(-194)).union([-120, -60, -59, -12])
            return (-364...0).filter { !gaps.contains($0) }
        }
    }

    /// The estimated days: the last run of the month (after the one-day gap) and a few scattered days.
    var estimates: Set<Int> {
        switch self {
        case .month: return [-2, -1, 0, -22]
        case .year: return Set(stride(from: -350, through: -10, by: 37))
        default: return []
        }
    }
}

enum KitData {
    static let calendar = Calendar.current
    static let now = Date()
    static var today: Date { calendar.startOfDay(for: now) }

    static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today).map { calendar.startOfDay(for: $0) } ?? today
    }

    /// A deterministic wobble in -0.5...0.5.
    static func jitter(_ i: Int) -> Double { Double(((i * 37 + 11) % 17 + 17) % 17) / 17 - 0.5 }

    static func wave(_ offset: Int, base: Double, swing: Double) -> Double {
        base + swing * (0.6 * sin(Double(offset) / 4.3) + 0.8 * jitter(offset + 400))
    }

    static func window(_ range: ChartRange, offsets: [Int]) -> ClosedRange<Date> {
        ChartAxis.window(range, now: now, firstDataDay: offsets.min().map(day), calendar: calendar)
    }

    static func points(_ sample: KitSample, base: Double, swing: Double, every: Int = 1,
                       clamp: ClosedRange<Double>? = nil, series: (Int) -> String = { _ in "default" }) -> [DailyPoint] {
        let kept = sample.offsets.count > 3 ? sample.offsets.filter { $0 % max(1, every) == 0 } : sample.offsets
        return kept.map { offset in
            var value = wave(offset, base: base, swing: swing)
            if let clamp { value = min(clamp.upperBound, max(clamp.lowerBound, value)) }
            return DailyPoint(day: day(offset), value: value, isEstimate: sample.estimates.contains(offset),
                              series: series(offset))
        }
    }

    /// Charge bands from the scorer's own thresholds, as a screen builds them.
    static var chargeBands: ScoreBands {
        ScoreBands([
            .init(upperBound: RecoveryScorer.bandRedMax, color: StrandPalette.statusCritical, name: "Low"),
            .init(upperBound: RecoveryScorer.bandYellowMax, color: StrandPalette.statusWarning, name: "Moderate"),
            .init(upperBound: .infinity, color: StrandPalette.chargeColor, name: "High"),
        ])
    }

    static let integer: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0))) }
    static let oneDecimal: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(1))) }
    static let signedOneDecimal: (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
    }
    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60) h \(total % 60) m" : "\(total) m"
    }
}

// MARK: - Gallery scaffolding

/// A titled section of the gallery, drawn only when `--demo-kit-only` allows it.
private struct KitSection<Content: View>: View {
    let id: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if KitGallery.shows(id) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader(LocalizedStringKey(title), trailing: id)
                content()
            }
        }
    }
}

/// Reports a view's height into a binding (the gallery prints it beside the case title).
private struct KitMeasured: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        content.background(GeometryReader { geo in
            Color.clear
                .onAppear { height = geo.size.height }
                .onChangeCompat(of: geo.size.height) { height = $0 }
        })
    }
}

private extension View {
    func kitMeasured(_ height: Binding<CGFloat>) -> some View { modifier(KitMeasured(height: height)) }
}

private func kitPoints(_ value: CGFloat) -> String { "\(Int(value.rounded())) pt" }

/// One chart case: its title and measured heights, then a card with the optional readout and the chart.
/// The selection is the case's own, so `--demo-chart-select` scrubs every chart independently.
private struct KitChartCase<Chart: View>: View {
    let title: String
    var readout: ((Date?) -> ReadoutContent)? = nil
    @ViewBuilder let chart: (Binding<Date?>) -> Chart
    @State private var selection: Date?
    @State private var chartHeight: CGFloat = 0
    @State private var readoutHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(verbatim: title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(verbatim: readout == nil ? kitPoints(chartHeight)
                                              : "\(kitPoints(readoutHeight)) + \(kitPoints(chartHeight))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    if let readout {
                        ValueReadout(readout(selection), isScrubbing: selection != nil)
                            .kitMeasured($readoutHeight)
                    }
                    chart($selection).kitMeasured($chartHeight)
                }
            }
        }
    }
}

// MARK: - Charts gallery

/// `--demo-screen kitcharts`.
struct KitChartsGallery: View {
    var body: some View {
        ScreenScaffold(title: "Kit charts", dateLine: "Every chart type in every state") {
            KitSection(id: "charge", title: "DailyBarChart.scores · Charge") { ChargeGallery() }
            KitSection(id: "hrv", title: "DailyLineChart · HRV") { HRVGallery() }
            KitSection(id: "spo2", title: "fixedDomainPoints · Blood oxygen") { SpO2Gallery() }
            KitSection(id: "skintemp", title: "DivergingBarChart · Skin temperature") { SkinTempGallery() }
            KitSection(id: "schedule", title: "RangeBarChart · Bedtime to wake") { ScheduleGallery() }
            KitSection(id: "stages", title: "StackedBarChart · Sleep stages") { StagesGallery() }
            KitSection(id: "mood", title: "DotStripChart · Mood") { MoodGallery() }
            KitSection(id: "weight", title: "SparsePointsChart · Weight") { WeightGallery() }
            KitSection(id: "vo2", title: "StepLineChart · VO2 max") { VO2Gallery() }
            KitSection(id: "steps", title: "DailyBarChart.totals · Steps") { StepsGallery() }
            KitSection(id: "intraday", title: "IntradayChart · Heart rate") { IntradayGallery() }
        }
    }
}

private struct ChargeGallery: View {
    static func readout(_ points: [DailyPoint]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: points, unit: "%", format: KitData.integer,
                                 context: selection == nil ? "7-day avg 52 %" : nil,
                                 valueColor: { KitData.chargeBands.band(for: $0).color })
        }
    }

    var body: some View {
        ForEach(KitSample.allCases, id: \.self) { sample in
            let points = KitData.points(sample, base: 58, swing: 38, clamp: 1...99)
            let window = KitData.window(sample.range, offsets: sample.offsets)
            KitChartCase(title: sample.title, readout: sample == .month ? Self.readout(points) : nil) { selection in
                DailyBarChart.scores(points, bands: KitData.chargeBands, bin: sample.range.totalsBin, unit: "%",
                                     state: sample.state("No Charge yet"), window: window,
                                     xStyle: sample.range.axisStyle, selection: selection,
                                     accessibilityTitle: "Charge")
            }
        }
    }
}

private struct HRVGallery: View {
    static func readout(_ points: [DailyPoint]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: points, nightly: true, unit: "ms", format: KitData.integer,
                                 context: selection == nil ? "7-day avg 61 ms · typical 52-78 ms" : nil)
        }
    }

    var body: some View {
        ForEach(KitSample.allCases, id: \.self) { sample in
            let points = KitData.points(sample, base: 64, swing: 22)
            let window = KitData.window(sample.range, offsets: sample.offsets)
            KitChartCase(title: sample.title, readout: sample == .month ? Self.readout(points) : nil) { selection in
                DailyLineChart(series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricPurple, points: points)],
                               typicalBand: 52...78, baseline: ChartReference(64, label: "Baseline 64"),
                               state: sample.state("No HRV readings yet"), window: window,
                               xStyle: sample.range.axisStyle,
                               y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                               selection: selection, accessibilityTitle: "Heart rate variability")
            }
        }
        let month = KitSample.month
        let rmssd = KitData.points(month, base: 64, swing: 22)
        let sdnn = KitData.points(month, base: 88, swing: 26)
        KitChartCase(title: "Two series (RMSSD + SDNN) · rolling band · M") { selection in
            DailyLineChart(series: [.init(id: "rmssd", name: "RMSSD", color: StrandPalette.metricPurple, points: rmssd),
                                    .init(id: "sdnn", name: "SDNN", color: StrandPalette.metricCyan, points: sdnn)],
                           rollingBand: month.offsets.map { (day: KitData.day($0), range: 50.0...(76.0 + Double($0) * 0.2)) },
                           window: KitData.window(.month, offsets: month.offsets), xStyle: .dayOfMonth,
                           y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                           selection: selection, accessibilityTitle: "Heart rate variability")
        }
    }
}

private struct SpO2Gallery: View {
    static func readout(_ points: [DailyPoint]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: points, nightly: true, unit: "%", format: KitData.integer,
                                 context: selection == nil ? "Lowest 93 % on 2 Oct" : nil)
        }
    }

    var body: some View {
        ForEach(KitSample.allCases, id: \.self) { sample in
            let points = KitData.points(sample, base: 96, swing: 3, clamp: 88...100)
            let window = KitData.window(sample.range, offsets: sample.offsets)
            KitChartCase(title: sample.title, readout: sample == .month ? Self.readout(points) : nil) { selection in
                DailyLineChart.fixedDomainPoints(points, domain: 85...100,
                                                 reference: ChartReference(95, label: "95 %"),
                                                 color: StrandPalette.metricCyan, joined: false,
                                                 state: sample.state("No blood oxygen readings yet"),
                                                 window: window, xStyle: sample.range.axisStyle,
                                                 selection: selection, accessibilityTitle: "Blood oxygen")
            }
        }
    }
}

private struct SkinTempGallery: View {
    static func readout(_ points: [DailyPoint]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: points, nightly: true, unit: "°C",
                                 format: KitData.signedOneDecimal,
                                 context: selection == nil ? "Difference from your baseline" : nil)
        }
    }

    var body: some View {
        ForEach(KitSample.allCases, id: \.self) { sample in
            let points = KitData.points(sample, base: 0, swing: 0.7)
            let window = KitData.window(sample.range, offsets: sample.offsets)
            KitChartCase(title: sample.title, readout: sample == .month ? Self.readout(points) : nil) { selection in
                DivergingBarChart(points: points, positive: StrandPalette.metricAmber, negative: StrandPalette.metricCyan,
                                  positiveLabel: "Warmer", negativeLabel: "Cooler",
                                  references: [ChartReference(0.5), ChartReference(-0.5)],
                                  bin: sample.range.totalsBin,
                                  state: sample.state("No skin temperature yet"), window: window,
                                  xStyle: sample.range.axisStyle,
                                  y: ChartValueAxis(unit: "°C", domain: .symmetric(minMagnitude: 0.5),
                                                    format: ChartValueAxis.decimals(1)),
                                  selection: selection, accessibilityTitle: "Skin temperature")
            }
        }
    }
}

private struct ScheduleGallery: View {
    static func nights(_ sample: KitSample) -> [RangeBarChart.Item] {
        sample.offsets.map { offset in
            let wakeDay = KitData.day(offset)
            let evening = KitData.day(offset - 1)
            let bed = evening.addingTimeInterval((22.9 + KitData.jitter(offset) * 2.2) * 3600)
            let wake = wakeDay.addingTimeInterval((6.8 + KitData.jitter(offset + 7) * 1.6) * 3600)
            return RangeBarChart.Item(day: wakeDay, start: bed, end: wake, isEstimate: sample.estimates.contains(offset))
        }
    }

    var body: some View {
        let clock = { (hour: Int, minute: Int) in
            KitData.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: KitData.today) ?? KitData.today
        }
        ForEach(KitSample.allCases, id: \.self) { sample in
            let items = Self.nights(sample)
            let spans = RangeBarChart.bin(items, by: sample.range.totalsBin)
            let readout: ((Date?) -> ReadoutContent)? = sample == .month || sample == .year
                ? { selection in ReadoutContent.range(selection: selection, in: spans, bin: sample.range.totalsBin) }
                : nil
            KitChartCase(title: sample.title, readout: readout) { selection in
                RangeBarChart(items: items, typicalStart: clock(22, 45)...clock(23, 30),
                              typicalEnd: clock(6, 30)...clock(7, 15), color: StrandPalette.restColor,
                              bin: sample.range.totalsBin, state: sample.state("No nights yet"),
                              window: KitData.window(sample.range, offsets: sample.offsets),
                              xStyle: sample.range.axisStyle, selection: selection,
                              accessibilityTitle: "Sleep schedule")
            }
        }
        // One early-evening bedtime: the clock axis widens above the 6 PM anchor instead of clipping it.
        let early = Self.nights(.three).enumerated().map { index, item -> RangeBarChart.Item in
            guard index == 1 else { return item }
            let evening = KitData.calendar.date(byAdding: .day, value: -1, to: item.day) ?? item.day
            return RangeBarChart.Item(day: item.day, start: evening.addingTimeInterval(17.5 * 3600), end: item.end)
        }
        KitChartCase(title: "W · a 5:30 PM bedtime (axis widens above 6 PM)") { selection in
            RangeBarChart(items: early, typicalStart: clock(22, 45)...clock(23, 30),
                          typicalEnd: clock(6, 30)...clock(7, 15), color: StrandPalette.restColor,
                          window: KitData.window(.week, offsets: KitSample.three.offsets),
                          xStyle: ChartRange.week.axisStyle, selection: selection,
                          height: NoopMetrics.chartHeightSecondary, accessibilityTitle: "Sleep schedule")
        }
    }
}

private struct StagesGallery: View {
    static let categories: [StackedBarChart.Category] = [
        .init(id: "deep", name: "Deep", color: StrandPalette.sleepDeep),
        .init(id: "rem", name: "REM", color: StrandPalette.sleepREM),
        .init(id: "light", name: "Light", color: StrandPalette.sleepLight),
        .init(id: "awake", name: "Awake", color: StrandPalette.sleepAwake),
    ]

    static func nights(_ sample: KitSample) -> [StackedBarChart.Day] {
        sample.offsets.map { offset in
            StackedBarChart.Day(day: KitData.day(offset), values: [
                "deep": 78 + 30 * KitData.jitter(offset),
                "rem": 100 + 36 * KitData.jitter(offset + 3),
                "light": 225 + 50 * KitData.jitter(offset + 5),
                "awake": 22 + 16 * KitData.jitter(offset + 9),
            ], isEstimate: sample.estimates.contains(offset))
        }
    }

    var body: some View {
        ForEach(KitSample.allCases, id: \.self) { sample in
            let nights = Self.nights(sample)
            KitChartCase(title: sample.title + " · deep highlighted") { selection in
                StackedBarChart(days: nights, categories: Self.categories, highlighted: "deep",
                                bin: sample.range.totalsBin, state: sample.state("No staged nights yet"),
                                window: KitData.window(sample.range, offsets: sample.offsets),
                                xStyle: sample.range.axisStyle, y: .durationMinutes(),
                                selection: selection, accessibilityTitle: "Deep sleep")
            }
        }
        KitChartCase(title: "Normalised share · M") { selection in
            StackedBarChart(days: Self.nights(.month), categories: Self.categories, normalised: true,
                            window: KitData.window(.month, offsets: KitSample.month.offsets), xStyle: .dayOfMonth,
                            y: .durationMinutes(), selection: selection,
                            height: NoopMetrics.chartHeightSecondary, accessibilityTitle: "Stage share")
        }
    }
}

private struct MoodGallery: View {
    static func color(_ level: Int) -> Color {
        switch level {
        case 1: return StrandPalette.metricRose
        case 2: return StrandPalette.metricAmber
        case 3: return StrandPalette.textSecondary
        case 4: return StrandPalette.metricPurple
        default: return StrandPalette.statusPositive
        }
    }

    var body: some View {
        ForEach(KitSample.allCases, id: \.self) { sample in
            let points = KitData.points(sample, base: 3.2, swing: 2.4, every: 2, clamp: 1...5)
            KitChartCase(title: sample.title) { selection in
                DotStripChart(points: points, levels: 1...5,
                              levelLabels: [1: "Awful", 2: "Low", 3: "Okay", 4: "Good", 5: "Great"],
                              color: Self.color, state: sample.state("No check-ins yet"),
                              window: KitData.window(sample.range, offsets: sample.offsets),
                              xStyle: sample.range.axisStyle, selection: selection,
                              height: NoopMetrics.chartHeightSecondary, accessibilityTitle: "Mood")
            }
        }
    }
}

private struct WeightGallery: View {
    static func readout(_ points: [DailyPoint]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: points, unit: "kg", format: KitData.oneDecimal,
                                 context: selection == nil ? "−1.2 kg since Jul" : nil)
        }
    }

    /// Weigh-ins every few days with a three-week gap in the middle of the quarter.
    static func weighIns(_ offsets: [Int]) -> [DailyPoint] {
        offsets.map { offset in
            DailyPoint(day: KitData.day(offset), value: 72.4 - Double(offset) * 0.012 + 0.9 * KitData.jitter(offset),
                       isEstimate: offset == -5)
        }
    }

    var body: some View {
        let quarter = stride(from: -89, through: 0, by: 3).filter { !(-60 ... -40).contains($0) }
        let cases: [(String, ChartState, ChartRange, [Int])] = [
            ("Loading", .loading, .quarter, []),
            ("Empty", .empty("No weigh-ins yet"), .quarter, []),
            ("1 reading · W", .ready, .week, [0]),
            ("3 readings · W", .ready, .week, [-6, -3, 0]),
            ("3M, a three-week gap, one estimate", .ready, .quarter, quarter),
            ("Y, sparse", .ready, .year, stride(from: -360, through: 0, by: 9).filter { !(-250 ... -200).contains($0) }),
        ]
        ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
            let points = Self.weighIns(item.3)
            KitChartCase(title: item.0, readout: index == 4 ? Self.readout(points) : nil) { selection in
                SparsePointsChart(points: points, color: StrandPalette.metricPurple, state: item.1,
                                  window: KitData.window(item.2, offsets: item.3), xStyle: item.2.axisStyle,
                                  y: ChartValueAxis(unit: "kg", domain: .fitted(minSpan: 2),
                                                    format: ChartValueAxis.decimals(1)),
                                  selection: selection, accessibilityTitle: "Weight")
            }
        }
    }
}

private struct VO2Gallery: View {
    static func readout(_ points: [DailyPoint]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: points, unit: "ml/kg/min", format: KitData.oneDecimal,
                                 context: selection == nil ? "\(points.count) readings in 6M" : nil)
        }
    }

    /// Weekly estimates; before `methodChange` days ago they come from a different estimator (a new run).
    static func readings(_ offsets: [Int], methodChange: Int = -120) -> [DailyPoint] {
        offsets.map { offset in
            DailyPoint(day: KitData.day(offset), value: 41 + Double(offset) * -0.008 + 1.6 * KitData.jitter(offset),
                       isEstimate: offset < methodChange, series: offset < methodChange ? "uth" : "nes")
        }
    }

    var body: some View {
        let cases: [(String, ChartState, ChartRange, [Int])] = [
            ("Loading", .loading, .half, []),
            ("Empty", .empty("No VO2 max estimates yet"), .half, []),
            ("1 reading · M", .ready, .month, [-3]),
            ("3 readings · M", .ready, .month, [-17, -10, -3]),
            ("6M weekly, held to today", .ready, .half, Array(stride(from: -178, through: -3, by: 7))),
            ("M · last reading 40 days ago, held across", .ready, .month, [-40]),
            ("W · the previous reading held until day 4", .ready, .week, [-10, -3]),
            ("Y, method change (hollow, dashed) and a gap", .ready, .year,
             stride(from: -360, through: -3, by: 7).filter { !(-260 ... -200).contains($0) }),
        ]
        ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
            let points = Self.readings(item.3)
            KitChartCase(title: item.0, readout: index == 4 ? Self.readout(points) : nil) { selection in
                StepLineChart(points: points, color: StrandPalette.chargeColor,
                              reference: ChartReference(38, label: "Typical at 45"),
                              state: item.1, window: KitData.window(item.2, offsets: item.3),
                              xStyle: item.2.axisStyle,
                              y: ChartValueAxis(unit: "ml/kg/min", domain: .fitted(minSpan: 6)),
                              selection: selection, accessibilityTitle: "VO2 max")
            }
        }
    }
}

private struct StepsGallery: View {
    /// Daily intensity minutes over the quarter, every third day without any.
    static func intensityMinutes() -> [DailyPoint] {
        var points: [DailyPoint] = []
        for offset in -89...0 where offset % 3 != 0 {
            let value: Double = max(0, KitData.wave(offset, base: 26, swing: 22))
            points.append(DailyPoint(day: KitData.day(offset), value: value))
        }
        return points
    }

    /// The weekly sum under the selection (else the latest), with "So far this week" on the running week.
    static func weeklyReadout(_ selection: Date?, weeks: [DailyPoint], partial: Set<Date>) -> ReadoutContent {
        let selected: DailyPoint? = selection == nil
            ? weeks.last : ChartSelection.point(for: selection, in: weeks, unit: .weekOfYear)
        let soFar = selected.map { partial.contains($0.day) } ?? false
        return ReadoutContent.daily(selection: selection, in: weeks, bin: .weekOfYear, unit: "min",
                                    format: KitData.integer, context: soFar ? "So far this week" : nil)
    }

    static func readout(_ binned: [DailyPoint], bin: Calendar.Component) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.daily(selection: selection, in: binned, bin: bin, unit: "steps", format: KitData.integer,
                                 context: selection == nil ? "avg 8,420 steps/day" : (bin == .day ? nil : "Daily average"))
        }
    }

    var body: some View {
        let cases: [(String, ChartState, ChartRange, [Int])] = [
            ("Loading", .loading, .month, []),
            ("Empty", .empty("No steps yet"), .month, []),
            ("W · daily bars", .ready, .week, Array(-6...0)),
            ("M · daily bars, gaps, estimates", .ready, .month, KitSample.month.offsets),
            ("3M · weekly bins (mean per day)", .ready, .quarter, (-89...0).filter { !(-40 ... -33).contains($0) }),
            ("Y · monthly bins (mean per day)", .ready, .year, KitSample.year.offsets),
            ("All · 20 days of history (daily bars by span)", .ready, .all, Array(-19...0)),
        ]
        ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
            let points = item.3.map { offset in
                DailyPoint(day: KitData.day(offset), value: max(400, KitData.wave(offset, base: 8_600, swing: 4_200)),
                           isEstimate: KitSample.month.estimates.contains(offset) && item.2 == .month)
            }
            let window = KitData.window(item.2, offsets: item.3)
            let bin = item.2.totalsBin(for: window)
            let binned = DailyBarChart.bin(points, by: bin, aggregation: .mean)
            KitChartCase(title: item.0, readout: index >= 3 ? Self.readout(binned, bin: bin) : nil) { selection in
                DailyBarChart.totals(points, color: StrandPalette.metricCyan,
                                     goal: ChartReference(10_000, label: "Goal 10,000"),
                                     bin: bin, state: item.1, window: window,
                                     xStyle: item.2.axisStyle,
                                     y: ChartValueAxis(unit: "steps", domain: .fitted(minSpan: 2_000, includeZero: true)),
                                     selection: selection, accessibilityTitle: "Steps")
            }
        }
        // Weekly SUMS (intensity minutes against a weekly goal): the running week is drawn as partial.
        let minutes = Self.intensityMinutes()
        let quarter = KitData.window(.quarter, offsets: [])
        let weeks = DailyBarChart.bin(minutes, by: .weekOfYear, aggregation: .sum)
        let partial = DailyBarChart.partialBins(minutes, by: .weekOfYear, window: quarter)
        KitChartCase(title: "3M · weekly sums, the running week partial",
                     readout: { selection in Self.weeklyReadout(selection, weeks: weeks, partial: partial) }) { selection in
            DailyBarChart.totals(minutes, color: StrandPalette.effortColor, goal: ChartReference(150, label: "150 min"),
                                 bin: .weekOfYear, aggregation: .sum, window: quarter, xStyle: ChartRange.quarter.axisStyle,
                                 y: ChartValueAxis(unit: "min", domain: .fitted(minSpan: 60, includeZero: true)),
                                 selection: selection, accessibilityTitle: "Intensity minutes")
        }
    }
}

private struct IntradayGallery: View {
    static func readout(_ samples: [IntradayChart.Sample]) -> (Date?) -> ReadoutContent {
        { selection in
            ReadoutContent.intraday(selection: selection, in: samples, unit: "bpm", format: KitData.integer,
                                    context: selection == nil ? "Resting 56 bpm" : nil)
        }
    }

    static var day: ClosedRange<Date> {
        KitData.today...(KitData.calendar.dateInterval(of: .day, for: KitData.now)?.end
                         ?? KitData.today.addingTimeInterval(86_400))
    }

    static func at(_ hours: Double) -> Date { day.lowerBound.addingTimeInterval(hours * 3600) }

    static func heartRate(minutes: [Int]) -> [IntradayChart.Sample] {
        minutes.map { minute in
            let hour = Double(minute) / 60
            let asleep = hour < 6.8 ? -12.0 : 0
            let run = hour >= 17.5 && hour < 18.33 ? 78.0 : 0
            let bpm = 66 + asleep + 12 * sin(hour / 3.4) + 7 * KitData.jitter(minute) + run
            return IntradayChart.Sample(time: day.lowerBound.addingTimeInterval(Double(minute) * 60), value: bpm)
        }
    }

    static var bands: [IntradayChart.Band] {
        [.init(id: "sleep", start: at(0), end: at(6.8), color: StrandPalette.restColor, label: "Asleep"),
         .init(id: "off", start: at(13), end: at(14), color: StrandPalette.textTertiary, label: "Off wrist", hatched: true),
         .init(id: "run", start: at(17.5), end: at(18.33), color: StrandPalette.effortColor, label: "Run")]
    }

    static var stress: [IntradayChart.Sample] {
        heartRate(minutes: Array(stride(from: 420, to: 1320, by: 15))).map { sample in
            IntradayChart.Sample(time: sample.time, value: min(3, max(0, (sample.value - 50) / 30)))
        }
    }

    static var markers: [IntradayChart.Marker] {
        [.init(id: "woke", time: at(6.8), label: "Woke", color: StrandPalette.textSecondary)]
    }

    var body: some View {
        let gappy = Array(stride(from: 0, to: 1440, by: 5)).filter { !(780..<840).contains($0) && !(300..<330).contains($0) }
        let dense = Array(0..<1440).filter { !(780..<840).contains($0) }
        let cases: [(String, ChartState, [Int])] = [
            ("Loading", .loading, []),
            ("Empty", .empty("No heart rate yet today"), []),
            ("1 sample", .ready, [600]),
            ("3 samples (two joined, one alone)", .ready, [600, 605, 700]),
            ("A day with gaps · 5-minute buckets", .ready, gappy),
            ("A dense day · 1-minute samples", .ready, dense),
        ]
        ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
            let samples = Self.heartRate(minutes: item.2)
            KitChartCase(title: item.0, readout: index == 4 ? Self.readout(samples) : nil) { selection in
                IntradayChart(samples: samples, bucketSeconds: item.2.count > 1000 ? 60 : 300,
                              bands: Self.bands, markers: Self.markers,
                              references: [ChartReference(56, label: "Resting 56")],
                              state: item.1, window: Self.day,
                              y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                              selection: selection, accessibilityTitle: "Heart rate")
            }
        }
        KitChartCase(title: "Compact (Today card)") { selection in
            IntradayChart(samples: Self.heartRate(minutes: gappy), bucketSeconds: 300, bands: Self.bands,
                          references: [ChartReference(56, label: "Resting 56")], compact: true,
                          window: Self.day, y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                          selection: selection, accessibilityTitle: "Heart rate today")
        }
        KitChartCase(title: "Compact, loading") { selection in
            IntradayChart(samples: [], bucketSeconds: 300, compact: true, state: .loading, window: Self.day,
                          y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                          selection: selection, accessibilityTitle: "Heart rate today")
        }
        KitChartCase(title: "Stress 0-3 with value bands") { selection in
            IntradayChart(samples: Self.stress,
                          bucketSeconds: 900, color: StrandPalette.stressColor,
                          valueBands: [.init(id: "low", range: 0...1, color: StrandPalette.statusPositive, label: "Low"),
                                       .init(id: "mid", range: 1...2, color: StrandPalette.statusWarning, label: "Medium"),
                                       .init(id: "high", range: 2...3, color: StrandPalette.statusCritical, label: "High")],
                          window: Self.at(7)...Self.at(22),
                          y: ChartValueAxis(unit: nil, domain: .fixed(0...3), ticks: [0, 1, 2, 3]),
                          selection: selection, height: NoopMetrics.chartHeightSecondary,
                          accessibilityTitle: "Stress")
        }
    }
}

// MARK: - Components gallery

/// `--demo-screen kitcomponents`.
struct KitComponentsGallery: View {
    var body: some View {
        ScreenScaffold(title: "Kit components", dateLine: "Every component in every state") {
            KitSection(id: "rings", title: "ScoreRing") { RingsGallery() }
            KitSection(id: "readout", title: "ValueReadout") { ReadoutGallery() }
            KitSection(id: "stats", title: "StatGrid") { StatsGallery() }
            KitSection(id: "tiles", title: "MetricTile") { TilesGallery() }
            KitSection(id: "about", title: "AboutDisclosure") { AboutGallery() }
            KitSection(id: "lists", title: "NoopListSection · NoopListRow") { ListsGallery() }
            KitSection(id: "readings", title: "ReadingsList") { ReadingsGallery() }
            KitSection(id: "stepper", title: "PeriodStepper") { StepperGallery() }
            KitSection(id: "headers", title: "SectionHeader") { HeadersGallery() }
            KitSection(id: "ranges", title: "RangeControl") { RangesGallery() }
            KitSection(id: "small", title: "Small pieces") { SmallPiecesGallery() }
        }
    }
}

/// A labelled component case with its measured height.
private struct KitCase<Content: View>: View {
    let title: String
    var carded = true
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(verbatim: kitPoints(height))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if carded {
                NoopCard { content().kitMeasured($height) }
            } else {
                content().kitMeasured($height)
            }
        }
    }
}

private struct RingsGallery: View {
    var body: some View {
        KitCase(title: "64 · 88 · 140 pt, Charge 41 / 92") {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                ScoreRing(fraction: 0.41, value: "41", color: KitData.chargeBands.band(for: 41).color, diameter: 64)
                ScoreRing(fraction: 0.92, value: "92", caption: "Charge",
                          color: KitData.chargeBands.band(for: 92).color, diameter: 88)
                ScoreRing(fraction: 0.62, value: "62", caption: "of 100",
                          color: KitData.chargeBands.band(for: 62).color, diameter: 140)
            }
            .frame(maxWidth: .infinity)
        }
        KitCase(title: "nil (no score) · loading · 0 · 100 · 3 %") {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                ScoreRing(fraction: nil, value: "", caption: "Rest", color: StrandPalette.restColor, diameter: 56)
                ScoreRing(fraction: 0.5, value: "50", caption: "Effort", color: StrandPalette.effortColor,
                          diameter: 56, isLoading: true)
                ScoreRing(fraction: 0, value: "0", color: StrandPalette.statusCritical, diameter: 56)
                ScoreRing(fraction: 1, value: "100", color: StrandPalette.chargeColor, diameter: 56)
                ScoreRing(fraction: 0.03, value: "3", color: StrandPalette.statusCritical, diameter: 56)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ReadoutGallery: View {
    var body: some View {
        let latest = KitData.day(0)
        KitCase(title: "Latest") {
            ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(latest, period: .night),
                                        value: "62", unit: "ms", context: "7-day avg 61 ms · typical 52-78 ms"))
        }
        KitCase(title: "Scrubbing (a selected day)") {
            ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(KitData.day(-5), period: .day),
                                        value: "54", unit: "ms", context: "−8 ms vs typical"), isScrubbing: true)
        }
        KitCase(title: "Loading") {
            ValueReadout(ReadoutContent(dateLine: "", value: nil, unit: "ms"), isLoading: true)
        }
        KitCase(title: "No value, no context") {
            ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(KitData.day(-3), period: .day),
                                        value: nil, unit: "ms"))
        }
        KitCase(title: "Score in its band colour") {
            ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(latest, period: .day), value: "31",
                                        unit: "%", context: "Low · 7-day avg 48 %",
                                        valueColor: KitData.chargeBands.band(for: 31).color))
        }
        KitCase(title: "Long values, estimate, week") {
            ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(KitData.day(-60), period: .week),
                                        value: "12,345,678", unit: "steps",
                                        context: "Daily average over the whole week, including two estimated days",
                                        isEstimate: true))
        }
        KitCase(title: "Month, duration") {
            ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(KitData.day(-400), period: .month),
                                        value: KitData.hoursMinutes(452), unit: nil, context: "Average a night"))
        }
    }
}

private struct StatsGallery: View {
    var body: some View {
        KitCase(title: "2 items", carded: false) {
            StatGrid([StatItem("Average", value: "61", unit: "ms"), StatItem("Typical", value: "52–78", unit: "ms")])
        }
        KitCase(title: "3 items · columns 3, one missing", carded: false) {
            StatGrid([StatItem("Average", value: "8,420", unit: "steps"),
                      StatItem("Total", value: "252,600", unit: "steps"),
                      StatItem("Best day", value: nil, unit: "steps")], columns: 3)
        }
        KitCase(title: "4 items · columns 2, details", carded: false) {
            StatGrid([StatItem("Average", value: "61", unit: "ms"),
                      StatItem("Typical", value: "52–78", unit: "ms"),
                      StatItem("Low", value: "42", unit: "ms", detail: "30 Sep"),
                      StatItem("High", value: "88", unit: "ms", detail: "3 Oct")])
        }
        KitCase(title: "4 items · columns 4 (Mac)", carded: false) {
            StatGrid([StatItem("Average", value: "96", unit: "%"), StatItem("Lowest night", value: "93", unit: "%"),
                      StatItem("Nights < 95 %", value: "3"), StatItem("Nights", value: "26")], columns: 4)
        }
        KitCase(title: "Loading", carded: false) {
            StatGrid([StatItem("Resting", value: nil, unit: "bpm"), StatItem("High", value: nil, unit: "bpm"),
                      StatItem("Low", value: nil, unit: "bpm")], columns: 3, isLoading: true)
        }
    }
}

private struct TilesGallery: View {
    private let spark: [Double] = [58, 61, 60, 64, 62, 59, 63, 66, 62, 61, 65, 64]
    private let columns = [GridItem(.flexible(), spacing: NoopMetrics.gap), GridItem(.flexible(), spacing: NoopMetrics.gap)]

    var body: some View {
        KitCase(title: "Grid reserving the trend slot", carded: false) {
            LazyVGrid(columns: columns, spacing: NoopMetrics.gap) {
                MetricTile(icon: "waveform.path.ecg", iconColor: StrandPalette.metricPurple, label: "HRV",
                           value: "62", unit: "ms", state: "Within range", trend: spark, reservesTrendSlot: true)
                MetricTile(icon: "heart", iconColor: StrandPalette.metricRose, label: "Resting HR", value: "57",
                           unit: "bpm", state: "High", stateTone: .warning, reservesTrendSlot: true)
                MetricTile(icon: "figure.walk", iconColor: StrandPalette.metricCyan, label: "Steps", value: "8,412",
                           unit: "steps", trend: Array(spark.reversed()), reservesTrendSlot: true, isEstimate: true)
                MetricTile(icon: "scalemass", iconColor: StrandPalette.metricAmber, label: "Weight", value: nil,
                           unit: "kg", reservesTrendSlot: true)
                MetricTile(icon: "drop", iconColor: StrandPalette.metricCyan, label: "Blood oxygen", value: "97",
                           unit: "%", state: "Last night · 4 Oct", reservesTrendSlot: true, isLoading: true)
                MetricTile(icon: "lungs", iconColor: StrandPalette.metricPurple, label: "Respiratory rate, sleeping",
                           value: "14.2", unit: "rpm", state: "Within your usual range for this time of year",
                           trend: spark, reservesTrendSlot: true)
            }
        }
        KitCase(title: "Grid without trends", carded: false) {
            LazyVGrid(columns: columns, spacing: NoopMetrics.gap) {
                MetricTile(icon: "thermometer.medium", iconColor: StrandPalette.metricAmber, label: "Skin temp",
                           value: "+0.3", unit: "°C", state: "Warmer", stateTone: .warning)
                MetricTile(icon: "flame", iconColor: StrandPalette.effortColor, label: "Calories", value: "2,410",
                           unit: "kcal")
                MetricTile(icon: "bed.double", iconColor: StrandPalette.restColor, label: "Asleep",
                           value: KitData.hoursMinutes(402), unit: nil, state: "Below need", stateTone: .critical)
                MetricTile(icon: "figure.run", iconColor: StrandPalette.chargeColor, label: "VO2 max",
                           value: "41.2", unit: "ml/kg/min", isEstimate: true)
            }
        }
    }
}

private struct AboutGallery: View {
    var body: some View {
        KitCase(title: "Collapsed", carded: false) {
            AboutDisclosure("About HRV", paragraphs: [
                "Heart rate variability is the variation between heartbeats, measured overnight as RMSSD.",
                "Nara compares each night with your own usual range, not a population average.",
            ])
        }
        KitCase(title: "Expanded, custom content", carded: false) {
            AboutDisclosure(initiallyExpanded: true) {
                Text(verbatim: "Blood oxygen is read during sleep. A strap estimate is drawn hollow.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: "Not a medical device.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                NoopButton("How it is measured", kind: .tertiary) {}
            }
        }
    }
}

private struct ListsGallery: View {
    var body: some View {
        KitCase(title: "Icon rows, subtitle, value, no chevron", carded: false) {
            NoopListSection("Data", footer: "Everything stays on this iPhone.") {
                Button {} label: {
                    NoopListRow(icon: "sensor", iconColor: StrandPalette.accent, title: "Devices", value: "WHOOP 4.0")
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                Button {} label: {
                    NoopListRow(icon: "internaldrive", title: "Storage", subtitle: "Last cleaned 3 days ago",
                                value: "1.2 GB")
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                NoopListRow(icon: "dot.radiowaves.left.and.right", title: "Strap", value: "Re-pair to sync",
                            valueTone: .warning)
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                NoopListRow(icon: "square.and.arrow.up", title: "Export", showsChevron: false)
            }
            .buttonStyle(.plain)
        }
        KitCase(title: "No icons, long title and value", carded: false) {
            NoopListSection {
                NoopListRow(icon: nil, title: "A very long settings row title that has to truncate on a phone",
                            value: "A long value too")
                NoopListDivider()
                NoopListRow(icon: nil, title: "Notifications", value: "On")
            }
        }
    }
}

private struct ReadingsGallery: View {
    var body: some View {
        let rows = (0..<12).map { i in
            ReadingsList.Row(id: "\(i)", date: ReadoutContent.dateLine(KitData.day(-i), period: .day),
                             value: "\(58 + (i * 7) % 13) ms", source: i % 3 == 0 ? "Apple Health" : "WHOOP")
        }
        KitCase(title: "12 readings: 7 + Show all", carded: false) {
            ReadingsList(rows: rows, onShowAll: {})
        }
        KitCase(title: "3 readings, no sources", carded: false) {
            ReadingsList(rows: rows.prefix(3).map { ReadingsList.Row(id: $0.id, date: $0.date, value: $0.value) },
                         onShowAll: {})
        }
    }
}

private struct StepperGallery: View {
    @State private var offset = 0
    var body: some View {
        KitCase(title: "Night, title opens a picker") {
            PeriodStepper(title: offset == 0 ? "Last night" : "\(offset + 1) nights ago",
                          subtitle: ReadoutContent.dateLine(KitData.day(-offset), period: .night),
                          canGoBack: offset < 3, canGoForward: offset > 0,
                          onBack: { offset += 1 }, onForward: { offset -= 1 }, onTitleTap: {})
        }
        KitCase(title: "Week, newest (forward disabled)") {
            PeriodStepper(title: "This week", subtitle: ReadoutContent.dateLine(KitData.day(0), period: .week),
                          canGoBack: true, canGoForward: false, onBack: {}, onForward: {})
        }
        KitCase(title: "Today, no subtitle, oldest (back disabled)") {
            PeriodStepper(title: "Today", canGoBack: false, canGoForward: false, onBack: {}, onForward: {})
        }
        KitCase(title: "Long subtitle") {
            PeriodStepper(title: "Wednesday", subtitle: "Wed 30 Sep 2026, imported from Apple Health",
                          canGoBack: true, canGoForward: true, onBack: {}, onForward: {})
        }
    }
}

private struct HeadersGallery: View {
    var body: some View {
        KitCase(title: "Plain · trailing · button · link · long", carded: false) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Trends")
                SectionHeader("Readings", trailing: "Last 7")
                SectionHeader("Key metrics", action: .button(label: "Edit") {})
                SectionHeader("Events", action: .link(label: "See all") {
                    Text(verbatim: "All events").padding()
                })
                SectionHeader("Workouts", trailing: "This week", action: .button(label: "See all") {})
                SectionHeader("A section title long enough to need truncating", action: .button(label: "See all") {})
            }
        }
    }
}

private struct RangesGallery: View {
    @State private var all: ChartRange = .month
    @State private var some: ChartRange = .year
    @State private var few: ChartRange = .quarter
    @State private var none: ChartRange = .month

    var body: some View {
        KitCase(title: "All ranges available", carded: false) {
            RangeControl(selection: $all)
        }
        KitCase(title: "History fills 3 months: Y selected shows as 3M", carded: false) {
            RangeControl(selection: $some, isAvailable: { ($0.days ?? 0) <= 90 })
        }
        KitCase(title: "Two weeks of history: W + All", carded: false) {
            RangeControl(selection: $few, isAvailable: { ($0.days ?? 0) <= 7 })
        }
        KitCase(title: "Offered subset (W M 3M) without All", carded: false) {
            RangeControl(selection: $all, options: [.week, .month, .quarter])
        }
        KitCase(title: "Nothing to choose: hidden, space reserved", carded: false) {
            RangeControl(selection: $none, options: [.week], reservesSpaceWhenHidden: true)
                .overlay(RoundedRectangle(cornerRadius: NoopMetrics.insetRadius)
                    .strokeBorder(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
    }
}

private struct SmallPiecesGallery: View {
    @State private var hidden: Set<String> = ["SDNN"]
    var body: some View {
        KitCase(title: "InlineNotice: warning + action, titled, critical, in a card", carded: false) {
            VStack(spacing: NoopMetrics.gap) {
                InlineNotice("Your strap needs re-pairing before it can sync.", tone: .warning,
                             action: .init("Re-pair") {})
                InlineNotice("History is still syncing from your strap. Nights appear as they arrive.",
                             title: "Syncing")
                InlineNotice("This backup is not encrypted.", tone: .critical)
                NoopCard {
                    InlineNotice("Apple Health is not connected.", tone: .neutral,
                                 action: .init("Connect") {}, placement: .inCard)
                }
            }
        }
        KitCase(title: "StatePill · TrendChip · SourceBadge") {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    StatePill("Within range", tone: .positive)
                    StatePill("High", tone: .warning)
                    StatePill("Estimate", tone: .neutral, showsDot: false)
                }
                HStack(spacing: NoopMetrics.space2) {
                    TrendChip(text: "+4 bpm", color: StrandPalette.statusWarning)
                    TrendChip(text: "−14.5 bpm", color: StrandPalette.statusPositive)
                    TrendChip(text: "0 ms")
                    SourceBadge("WHOOP")
                }
            }
        }
        KitCase(title: "StatTile row (older tile)", carded: false) {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                StatTile(label: "Resting HR", value: "54 bpm", delta: "−2 bpm", deltaColor: StrandPalette.statusPositive)
                StatTile(label: "Average", value: "61 ms", caption: "30 days",
                         sparkline: [58, 61, 60, 64, 62, 59, 63], sparkColor: StrandPalette.metricPurple)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        KitCase(title: "ChartLegend with a toggled series") {
            ChartLegend([
                ChartLegendItem(.line(StrandPalette.metricPurple, dashed: false), "RMSSD"),
                ChartLegendItem(.line(StrandPalette.metricCyan, dashed: false), "SDNN"),
                ChartLegendItem(.band(StrandPalette.metricPurple), "Typical range"),
                ChartLegendItem(.estimate(StrandPalette.metricPurple), "Estimate"),
                ChartLegendItem(.hatched(StrandPalette.textTertiary), "Off wrist"),
            ], hidden: hidden, onToggle: { id in
                if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
            })
        }
        KitCase(title: "ChartPlaceholder · EmptyChartMessage (compact)") {
            VStack(spacing: NoopMetrics.cardInnerSpacing) {
                ChartPlaceholder(height: NoopMetrics.chartHeightCompact)
                EmptyChartMessage("No heart rate yet today", height: NoopMetrics.chartHeightCompact)
            }
        }
        KitCase(title: ".loadingPlaceholder on a card", carded: false) {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(verbatim: "Resting heart rate").strandLabel()
                    Text(verbatim: "52 bpm").font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .loadingPlaceholder(true)
        }
        KitCase(title: "NoopButton kinds") {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                NoopButton("Primary", fullWidth: true) {}
                HStack(spacing: NoopMetrics.space2) {
                    NoopButton("Secondary", kind: .secondary) {}
                    NoopButton("Tertiary", kind: .tertiary) {}
                    NoopButton("Delete", kind: .destructive) {}
                }
            }
        }
    }
}
#endif
