import SwiftUI
import Charts
import StrandDesign

/// "Every reading": every skin-temperature sample or SpO₂ reading the strap banked over the last 24 hours,
/// read from the phone's own store (`Repository.bankedSkinTemp` / `bankedSpo2`) and plotted under the
/// detail page's daily chart.
///
/// Each signal's daily chart shows one number per night, which hides that the strap took tens of thousands of
/// skin-temperature samples and hundreds of SpO₂ readings behind it. This card is where they are visible.
/// Nothing here is scored or computed beyond a 5-minute mean for drawing: the values are the strap's own.
///
/// SpO₂ is drawn as points, not a line, because the strap writes it in short windows while the wearer
/// sleeps; the gap through the day is the strap's schedule (the page's About card says so).
struct BankedReadingsSection: View {
    enum Signal { case skinTemp, bloodOxygen }

    let signal: Signal
    let accent: Color

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    /// 0 = the last 24 hours ending now; each step back is the 24 hours before that.
    @State private var dayOffset = 0
    @State private var loaded: Loaded?
    /// The time under the finger; nil reads the newest reading.
    @State private var selected: Date?

    private struct Loaded {
        let offset: Int
        let from: Int
        let to: Int
        let series: KeyMetricReadings.BankedSeries
    }

    /// `preloaded` seeds the card with a window that is already read (previews, and tests that render it);
    /// the live card leaves it nil and loads from the store.
    init(signal: Signal, accent: Color, preloaded: (from: Int, to: Int, series: KeyMetricReadings.BankedSeries)? = nil) {
        self.signal = signal
        self.accent = accent
        _loaded = State(initialValue: preloaded.map { Loaded(offset: 0, from: $0.from, to: $0.to, series: $0.series) })
    }

    /// The strap's history lives on the phone for about a week (`v18AuxRetentionRows`), so step back that far.
    private static let maxDayOffset = 6
    /// A hole longer than this in the skin-temperature line is the strap off the wrist or not yet synced.
    private static let skinTempGapSeconds = 15 * 60

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: temperatureRaw)
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                header
                chart
                statsRow
                timelineLink
            }
        }
        .task(id: "\(signal)-\(dayOffset)-\(repo.refreshSeq)") { await load() }
        .onChangeCompat(of: dayOffset) { _ in selected = nil }
    }

    // MARK: Data

    private func window(offset: Int) -> (from: Int, to: Int) {
        let end = Int(Date().timeIntervalSince1970) - offset * 86_400
        return (end - 86_400, end)
    }

    private func load() async {
        let offset = dayOffset
        let w = window(offset: offset)
        let series = signal == .skinTemp
            ? await repo.bankedSkinTemp(from: w.from, to: w.to)
            : await repo.bankedSpo2(from: w.from, to: w.to)
        guard !Task.isCancelled else { return }
        loaded = Loaded(offset: offset, from: w.from, to: w.to, series: series)
    }

    /// The loaded window, only once it is the one being asked for (so stepping back never shows the old day's
    /// numbers under the new day's title).
    private var current: Loaded? { loaded.flatMap { $0.offset == dayOffset ? $0 : nil } }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text("Every reading")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .transaction { $0.animation = nil }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                stepButton(symbol: "chevron.left", label: "Earlier",
                           enabled: dayOffset < Self.maxDayOffset) { dayOffset += 1 }
                stepButton(symbol: "chevron.right", label: "Later", enabled: dayOffset > 0) { dayOffset -= 1 }
            }
        }
    }

    private var title: String {
        if dayOffset == 0 { return String(localized: "Last 24 hours") }
        let w = window(offset: dayOffset)
        let style = Date.FormatStyle().weekday(.abbreviated).hour()
        let start = Date(timeIntervalSince1970: TimeInterval(w.from)).formatted(style)
        let end = Date(timeIntervalSince1970: TimeInterval(w.to)).formatted(style)
        return String(localized: "\(start) to \(end)")
    }

    /// The period, then the reading under the finger (or the newest one).
    private var subtitle: String {
        guard let series = current?.series, series.count > 0 else { return title }
        let reading: (ts: Int, value: Double)? = {
            if let selected, let index = ChartSelection.nearestIndex(to: selected, in: series.points.map { date($0.ts) }) {
                return (series.points[index].ts, series.points[index].value)
            }
            return series.lastTs.flatMap { ts in series.lastValue.map { (ts, $0) } }
        }()
        guard let reading else { return title }
        let time = date(reading.ts).formatted(date: .omitted, time: .shortened)
        return String(localized: "\(title) · \(display(reading.value)) at \(time)")
    }

    private func stepButton(symbol: String, label: LocalizedStringKey, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            StrandHaptic.selection.play()
            action()
        } label: {
            Image(systemName: symbol)
                .font(StrandFont.icon(.inline).weight(.semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func display(_ value: Double) -> String {
        switch signal {
        case .skinTemp: return UnitFormatter.temperatureFromCelsius(value, unit: temperatureUnit)
        case .bloodOxygen: return "\(Int(value.rounded())) %"
        }
    }

    // MARK: Chart

    private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    /// Skin temperature arrives in °C; show it in the unit the user chose.
    private func shown(_ celsius: Double) -> Double {
        temperatureUnit == .fahrenheit ? UnitFormatter.celsiusToFahrenheit(celsius) : celsius
    }

    private var span: ClosedRange<Date> {
        let w = current.map { ($0.from, $0.to) } ?? window(offset: dayOffset)
        return date(w.0) ... date(w.1)
    }

    private var chartState: ChartState {
        guard let series = current?.series else { return .loading }
        guard series.count > 0 else {
            return .empty(String(localized: "No readings in this period"))
        }
        return .ready
    }

    @ViewBuilder private var chart: some View {
        let points = current?.series.points ?? []
        if signal == .skinTemp {
            IntradayChart(samples: points.map { IntradayChart.Sample(time: date($0.ts), value: shown($0.value)) },
                          bucketSeconds: Self.skinTempGapSeconds, color: accent, live: dayOffset == 0,
                          state: chartState, window: span,
                          y: ChartValueAxis(unit: UnitFormatter.temperatureUnit(temperatureUnit),
                                            domain: .fitted(minSpan: temperatureUnit == .fahrenheit ? 1.5 : 0.8),
                                            format: ChartValueAxis.decimals(1)),
                          selection: $selected, height: NoopMetrics.chartHeightSecondary,
                          accessibilityTitle: String(localized: "Skin temperature readings"))
        } else {
            spo2Chart(points: points)
        }
    }

    /// SpO₂ as points on the detail chart's fixed 85-100 % scale (widened only to show an outlier), with the
    /// same clock axis, scrub and frame as the kit charts.
    @ViewBuilder
    private func spo2Chart(points: [KeyMetricReadings.BankedSeries.Point]) -> some View {
        let axis = ChartValueAxis(unit: "%", domain: .fixed(85...100), ticks: [85, 90, 95, 100])
        let yLayout = axis.layout(for: points.map(\.value))
        let xLayout = ChartAxis.layout(span, style: .hours)
        let times = points.map { date($0.ts) }
        switch chartState {
        case .loading:
            ChartPlaceholder(height: NoopMetrics.chartHeightSecondary)
        case .empty(let message):
            EmptyChartMessage(message, height: NoopMetrics.chartHeightSecondary)
        case .ready:
            let selectedIndex = selected.flatMap { ChartSelection.nearestIndex(to: $0, in: times) }
            Chart {
                ForEach(points) { p in
                    PointMark(x: .value("Time", date(p.ts)), y: .value("SpO₂", p.value))
                        .foregroundStyle(accent.opacity(selectedIndex == nil ? 1 : NaraChartStyle.dimmedOpacity))
                        .symbolSize(points.count > NaraChartStyle.densePointThreshold
                                    ? NaraChartStyle.densePointSize : NaraChartStyle.pointSize)
                }
                if let selectedIndex {
                    SelectionRule(times[selectedIndex], unit: nil)
                    PointMark(x: .value("Time", times[selectedIndex]), y: .value("SpO₂", points[selectedIndex].value))
                        .foregroundStyle(accent)
                        .symbolSize(NaraChartStyle.selectedPointSize)
                }
            }
            .naraChartAxes(x: xLayout, y: yLayout)
            .chartOverlay { proxy in
                ChartScrubLayer(proxy: proxy, xs: times, selection: $selected)
            }
            .frame(height: NoopMetrics.chartHeightSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Blood oxygen readings"))
            .accessibilityValue(Text(subtitle))
        }
    }

    // MARK: Stats

    @ViewBuilder private var statsRow: some View {
        if let series = current?.series, series.count > 0 {
            HStack(alignment: .top, spacing: NoopMetrics.space4) {
                stat(String(localized: "Readings"), series.count.formatted())
                if let lo = series.minValue { stat(String(localized: "Lowest"), display(lo)) }
                if let hi = series.maxValue { stat(String(localized: "Highest"), display(hi)) }
                Spacer(minLength: 0)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(label).strandLabel()
            Text(value)
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var timelineLink: some View {
        NavigationLink {
            FullDayChartView(initialMetric: signal == .skinTemp ? .skinTemp : .spo2)
        } label: {
            HStack(spacing: NoopMetrics.space1) {
                Text("Open in Deep Timeline")
                Image(systemName: "chevron.right").font(StrandFont.icon(.inline))
            }
            .font(StrandFont.subhead.weight(.medium))
            .foregroundStyle(StrandPalette.accent)
            .frame(minHeight: NoopMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
