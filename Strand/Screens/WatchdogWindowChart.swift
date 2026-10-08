import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - The Watchdog half-hour trace
//
// One vital over Watchdog's 30-minute window, a sample per minute: what the strap read, what Watchdog
// expected at that minute, and the usual range around the expectation. Drawn on a real clock axis with the
// unit on the value axis; a missing minute is a gap, never a line across it; sparse vitals (resting HR,
// SpO₂) are points at the minutes they were read, not stretched across the window. Straight segments only.
//
// Not a kit chart yet (kit_issues: an IntradayChart "window" mode with an expected line and a band around
// it). It uses the kit's axes, scrub, selection rule, legend, placeholders and mark tokens, so it reads as
// one of them.

/// The per-minute arrays a trace is drawn from, aligned to clock minutes. Built from the engine's result
/// for drawing only: the vital's call ("In range", "Off") comes from `WatchdogLiveSnapshot` and does not
/// depend on any of this.
struct WatchdogTrace: Equatable {
    struct Minute: Identifiable, Equatable {
        /// The middle of the minute bucket.
        let time: Date
        let observed: Double?
        let expected: Double?
        let half: Double?
        /// Consecutive minutes with a reading share a run; a missing minute starts a new one.
        let run: Int
        var id: Date { time }

        var low: Double? { expected.flatMap { e in half.map { e - $0 } } }
        var high: Double? { expected.flatMap { e in half.map { e + $0 } } }

        var outside: Bool {
            guard let observed, let expected, let half, half > 0 else { return false }
            return abs(observed - expected) > half
        }

        /// 0 at the band edge, 1 at `tauSevere` band widths past it (the old trace's ink rule).
        var offStrength: Double? {
            guard outside, let observed, let expected, let half else { return nil }
            let ratio = abs(observed - expected) / max(half, 0.001)
            return min(1, (ratio - 1) / max(WatchdogConfig.tauSevere, 0.5))
        }
    }

    let window: ClosedRange<Date>
    let minutes: [Minute]
    /// Points only: a sparse vital read at a few still minutes.
    let pointsOnly: Bool
    /// The band is the widened learning band, not a trusted one.
    let provisional: Bool
    let unit: String
    let decimals: Int
    let minSpan: Double

    var readings: [Minute] { minutes.filter { $0.observed != nil } }

    /// The displayed unit of a Watchdog vital (the engine says "/min" for breathing).
    static func unit(for id: String, fahrenheit: Bool) -> String {
        switch id {
        case "hr", "rhr": return "bpm"
        case "hrv": return "ms"
        case "temp": return fahrenheit ? "°F" : "°C"
        case "resp": return "rpm"
        case "spo2": return "%"
        default: return ""
        }
    }

    /// The half-hour for one vital of `result`, in the user's temperature unit. `row` is the snapshot's row
    /// for the same vital (its trust and band readiness decide whether the band is provisional).
    @MainActor
    init?(result: WatchdogResult, row: WatchdogLiveSnapshot.MetricRow, fahrenheit: Bool) {
        let series: [Double], expected: [Double], range: [Double]
        switch row.id {
        case "hr": (series, expected, range) = (result.horizonHR, result.reconstructedHR, result.rangeHR)
        case "rhr": (series, expected, range) = (result.horizonRHR, result.reconstructedRHR, result.rangeRHR)
        case "hrv": (series, expected, range) = (result.horizonHRV, result.reconstructedHRV, result.rangeHRV)
        case "temp": (series, expected, range) = (result.horizonTemp, result.reconstructedTemp, result.rangeTemp)
        case "resp": (series, expected, range) = (result.horizonResp, result.reconstructedResp, result.rangeResp)
        case "spo2": (series, expected, range) = (result.horizonSpO2, result.reconstructedSpO2, result.rangeSpO2)
        default: return nil
        }
        let temp = row.id == "temp" && fahrenheit
        let observed = temp ? series.map(UnitFormatter.celsiusToFahrenheit) : series
        // The same masking and learning widening the snapshot applies before packing, so the band drawn
        // here is the band the call was made against.
        let gain = WatchdogLiveSnapshot.learningBandGain(row.trustPct)
        let hat = WatchdogLiveSnapshot.maskToRecorded(temp ? expected.map(UnitFormatter.celsiusToFahrenheit) : expected,
                                                      recorded: observed)
        let half = WatchdogLiveSnapshot.maskToRecorded(range, recorded: observed)
            .map { $0.isFinite ? $0 * gain * (temp ? 9.0 / 5.0 : 1) : $0 }
        let start = result.windowStartUnix
        let count = max(observed.count, 1)
        let step = Double(WatchdogConfig.contextSeconds) / Double(max(count, WatchdogConfig.seqLen))
        var run = 0
        var previous = false
        var minutes: [Minute] = []
        for i in 0..<observed.count {
            let value = observed[i].isFinite ? observed[i] : nil
            if value != nil, !previous { run += 1 }
            previous = value != nil
            let mid = Double(start) + (Double(i) + 0.5) * step
            minutes.append(Minute(time: Date(timeIntervalSince1970: mid), observed: value,
                                  expected: i < hat.count && hat[i].isFinite ? hat[i] : nil,
                                  half: i < half.count && half[i].isFinite && half[i] > 0 ? half[i] : nil,
                                  run: run))
        }
        self.window = Date(timeIntervalSince1970: TimeInterval(start))...Date(timeIntervalSince1970: TimeInterval(start + WatchdogConfig.contextSeconds))
        self.minutes = minutes
        self.pointsOnly = row.id == "rhr" || row.id == "spo2"
        self.provisional = !row.rangeReady
        self.unit = WatchdogTrace.unit(for: row.id, fahrenheit: fahrenheit)
        self.decimals = row.decimals
        self.minSpan = row.minSpan
    }
}

/// The trace as a chart. `compact` is the small tile form: no axes, no scrub, no legend.
struct WatchdogWindowChart: View {
    let trace: WatchdogTrace
    var compact: Bool = false
    @Binding var selection: Date?
    var height: CGFloat = NoopMetrics.chartHeightPrimary
    let accessibilityTitle: String

    private var bandFill: Color { StrandPalette.textTertiary.opacity(trace.provisional ? 0.08 : 0.16) }
    private var bandEdge: Color { StrandPalette.textTertiary.opacity(trace.provisional ? 0.55 : 0.4) }
    private var lineColor: Color { StrandPalette.textPrimary }

    private var legend: [ChartLegendItem] {
        var items = [ChartLegendItem(.line(lineColor, dashed: false), "Reading"),
                     ChartLegendItem(.line(StrandPalette.textSecondary, dashed: true), "Expected"),
                     ChartLegendItem(trace.provisional ? .hatched(StrandPalette.textTertiary) : .band(StrandPalette.textTertiary),
                                     trace.provisional ? "Usual range (learning)" : "Usual range")]
        if !trace.provisional, trace.minutes.contains(where: \.outside) {
            items.append(ChartLegendItem(.point(StrandPalette.statusWarning), "Off usual"))
        }
        return items
    }

    private var yLayout: ChartYAxisLayout {
        var values = trace.readings.compactMap(\.observed)
        for minute in trace.minutes {
            if let e = minute.expected {
                values.append(e)
                if let h = minute.half { values += [e - h, e + h] }
            }
        }
        let format: @Sendable (Double) -> String = trace.decimals == 0
            ? ChartValueAxis.integer : ChartValueAxis.decimals(trace.decimals)
        return ChartValueAxis(unit: trace.unit, domain: .fitted(minSpan: trace.minSpan), tickCount: 3,
                              format: format).layout(for: values)
    }

    /// Ten-minute clock ticks across the window ("9:10 9:20 9:30"); the kit's hour axis steps 15 minutes.
    private var xLayout: ChartXAxisLayout {
        let window = trace.window
        let cal = Calendar.current
        var marks: [Date] = []
        var tick = cal.dateInterval(of: .hour, for: window.lowerBound)?.start ?? window.lowerBound
        while tick <= window.upperBound {
            if tick >= window.lowerBound { marks.append(tick) }
            tick = tick.addingTimeInterval(600)
        }
        let labels = marks.map { $0.formatted(.dateTime.hour().minute()) }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let anchors: [ChartAxisLabelAnchor] = marks.map { mark in
            let f = mark.timeIntervalSince(window.lowerBound) / max(span, 1)
            return f < 0.08 ? .leading : (f > 0.92 ? .trailing : .center)
        }
        return ChartXAxisLayout(window: window, style: .hours, marks: marks, labels: labels, anchors: anchors, grid: marks)
    }

    private var xs: [Date] { trace.readings.map(\.time) }

    var body: some View {
        let showsLegend = !compact
        let plotHeight = max(0, height - (showsLegend ? NaraChartStyle.legendHeight + NaraChartStyle.legendSpacing : 0))
        VStack(alignment: .leading, spacing: NaraChartStyle.legendSpacing) {
            if trace.readings.isEmpty {
                EmptyChartMessage("No readings in this half-hour", height: plotHeight)
            } else {
                chart.frame(height: plotHeight)
            }
            if showsLegend {
                if trace.readings.isEmpty {
                    Color.clear.frame(height: NaraChartStyle.legendHeight)
                } else {
                    ChartLegend(legend)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private var chart: some View {
        let selected = selectedMinute
        let base = Chart {
            bandMarks
            edgeMarks
            expectedMarks
            readingLineMarks
            readingPointMarks
            selectionMarks(selected)
        }
        .naraChartAxes(x: xLayout, y: yLayout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(accessibilitySummary))

        if compact {
            base
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .naraChartCompact()
        } else {
            base.chartOverlay { proxy in
                ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
            }
        }
    }

    private var selectedMinute: WatchdogTrace.Minute? {
        guard !compact, let selection else { return nil }
        let readings = trace.readings
        return ChartSelection.nearestIndex(to: selection, in: readings.map(\.time)).map { readings[$0] }
    }

    private var bandMinutes: [WatchdogTrace.Minute] { trace.minutes.filter { $0.low != nil && $0.high != nil } }

    @ChartContentBuilder private var bandMarks: some ChartContent {
        ForEach(bandMinutes) { (m: WatchdogTrace.Minute) in
            AreaMark(x: .value("Time", m.time),
                     yStart: .value("Low", m.low ?? 0),
                     yEnd: .value("High", m.high ?? 0),
                     series: .value("Run", "band-\(m.run)"))
                .interpolationMethod(.linear)
                .foregroundStyle(bandFill)
        }
    }

    /// Dashed band edges while the band is the widened learning band.
    @ChartContentBuilder private var edgeMarks: some ChartContent {
        ForEach(trace.provisional ? bandMinutes : []) { (m: WatchdogTrace.Minute) in
            LineMark(x: .value("Time", m.time), y: .value("High", m.high ?? 0),
                     series: .value("Run", "hi-\(m.run)"))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(bandEdge)
        }
        ForEach(trace.provisional ? bandMinutes : []) { (m: WatchdogTrace.Minute) in
            LineMark(x: .value("Time", m.time), y: .value("Low", m.low ?? 0),
                     series: .value("Run", "lo-\(m.run)"))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(bandEdge)
        }
    }

    @ChartContentBuilder private var expectedMarks: some ChartContent {
        ForEach(trace.minutes.filter { $0.expected != nil }) { (m: WatchdogTrace.Minute) in
            LineMark(x: .value("Time", m.time), y: .value("Expected", m.expected ?? 0),
                     series: .value("Run", "exp-\(m.run)"))
                .interpolationMethod(.linear)
                .lineStyle(NaraChartStyle.meanLine)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ChartContentBuilder private var readingLineMarks: some ChartContent {
        ForEach(trace.pointsOnly ? [] : trace.readings) { (m: WatchdogTrace.Minute) in
            LineMark(x: .value("Time", m.time), y: .value("Reading", m.observed ?? 0),
                     series: .value("Run", "obs-\(m.run)"))
                .interpolationMethod(.linear)
                .lineStyle(NaraChartStyle.line)
                .foregroundStyle(lineColor)
        }
    }

    @ChartContentBuilder private var readingPointMarks: some ChartContent {
        ForEach(pointMinutes) { (m: WatchdogTrace.Minute) in
            PointMark(x: .value("Time", m.time), y: .value("Reading", m.observed ?? 0))
                .symbolSize(compact ? NaraChartStyle.densePointSize : NaraChartStyle.pointSize)
                .foregroundStyle(color(of: m))
        }
    }

    @ChartContentBuilder private func selectionMarks(_ selected: WatchdogTrace.Minute?) -> some ChartContent {
        SelectionRule(selected?.time, unit: nil)
        ForEach(selected.map { [$0] } ?? []) { (m: WatchdogTrace.Minute) in
            PointMark(x: .value("Time", m.time), y: .value("Reading", m.observed ?? 0))
                .symbolSize(NaraChartStyle.selectedPointSize)
                .foregroundStyle(color(of: m))
        }
    }

    /// Off-band minutes are coloured only against a trusted band: while the band is still being learned
    /// Watchdog makes no call, so neither does the trace.
    private func color(of minute: WatchdogTrace.Minute) -> Color {
        guard !trace.provisional else { return lineColor }
        return minute.offStrength.map(baselineOffColor) ?? lineColor
    }

    /// Every reading of a sparse vital, a reading alone between two gaps, and every minute off the band.
    private var pointMinutes: [WatchdogTrace.Minute] {
        let readings = trace.readings
        if trace.pointsOnly { return readings }
        let counts = Dictionary(grouping: readings, by: \.run).mapValues(\.count)
        return readings.filter { counts[$0.run] == 1 || ($0.outside && !trace.provisional) }
    }

    private var accessibilitySummary: String {
        let values = trace.readings.compactMap(\.observed)
        guard let low = values.min(), let high = values.max() else { return "No readings" }
        let lo = MonitorLabels.number(low, unit: trace.unit), hi = MonitorLabels.number(high, unit: trace.unit)
        let count = "\(values.count) of \(trace.minutes.count) minutes"
        return low == high ? "\(lo) \(trace.unit), \(count)" : "\(lo) to \(hi) \(trace.unit), \(count)"
    }
}
