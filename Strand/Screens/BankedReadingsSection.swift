import SwiftUI
import Charts
import StrandDesign

/// "Every reading": every skin-temperature sample or SpO₂ reading the strap banked over the last 24 hours,
/// read from the phone's own store (`Repository.bankedSkinTemp` / `bankedSpo2`), plotted, counted and
/// broken down by hour.
///
/// Each signal's Key Metrics tile and its daily chart show one number per night, which hides that the strap
/// took tens of thousands of skin-temperature samples and hundreds of SpO₂ readings behind it. This card is
/// where they are visible. Nothing here is scored or computed beyond a 5-minute mean for drawing: the
/// values are the strap's own.
///
/// SpO₂ is drawn as points, not a line, because the strap writes it in short windows while the wearer
/// sleeps; the gap through the day is the strap's schedule and the card says so.
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
    /// A worn hour of skin temperature is one sample per second.
    private static let fullHourOfSamples = 3_600

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: temperatureRaw)
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                readout
                chart
                statsRow
                hourlySection
                footer
                timelineLink
            }
        }
        .task(id: "\(signal)-\(dayOffset)-\(repo.refreshSeq)") { await load() }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Every reading").strandOverline()
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
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

    private func stepButton(symbol: String, label: LocalizedStringKey, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.textSecondary : StrandPalette.textTertiary.opacity(0.4))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Read-out

    private var readout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline ?? "—")
                .font(StrandFont.number(40))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(subtitle)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func display(_ value: Double) -> String {
        switch signal {
        case .skinTemp: return UnitFormatter.temperatureFromCelsius(value, unit: temperatureUnit)
        case .bloodOxygen: return "\(Int(value.rounded()))%"
        }
    }

    /// The newest raw reading in the window.
    private var headline: String? { current?.series.lastValue.map(display) }

    private var subtitle: String {
        guard let series = current?.series else { return String(localized: "Loading…") }
        guard series.count > 0, let last = series.lastTs, let first = series.firstTs else {
            return signal == .bloodOxygen
                ? String(localized: "No readings in this period")
                : String(localized: "No readings in this period yet")
        }
        let count = series.count.formatted()
        switch signal {
        case .skinTemp:
            return dayOffset == 0
                ? String(localized: "\(count) readings · newest \(relativeAgo(TimeInterval(last)))")
                : String(localized: "\(count) readings")
        case .bloodOxygen:
            let span = Date.FormatStyle(date: .omitted, time: .shortened)
            let from = Date(timeIntervalSince1970: TimeInterval(first)).formatted(span)
            let to = Date(timeIntervalSince1970: TimeInterval(last)).formatted(span)
            return String(localized: "\(count) readings · \(from) to \(to)")
        }
    }

    // MARK: Chart

    private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    /// Skin temperature arrives in °C; show it in the unit the user chose.
    private func shown(_ celsius: Double) -> Double {
        temperatureUnit == .fahrenheit ? UnitFormatter.celsiusToFahrenheit(celsius) : celsius
    }

    private struct Run: Identifiable {
        let id: Int
        let points: [KeyMetricReadings.BankedSeries.Point]
    }

    private var span: ClosedRange<Date> {
        let w = current.map { ($0.from, $0.to) } ?? window(offset: dayOffset)
        return date(w.0) ... date(w.1)
    }

    @ViewBuilder private var chart: some View {
        let points = current?.series.points ?? []
        Group {
            if signal == .skinTemp {
                skinTempChart(points: points)
            } else {
                spo2Chart(points: points)
            }
        }
        .frame(height: 190)
        .overlay {
            if let series = current?.series, series.count == 0 {
                Text(signal == .bloodOxygen ? "None while awake" : "No readings")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(signal == .skinTemp ? "Skin temperature readings" : "Blood oxygen readings"))
        .accessibilityValue(Text(subtitle))
    }

    private func skinTempChart(points: [KeyMetricReadings.BankedSeries.Point]) -> some View {
        let runs = KeyMetricReadings.runs(points, maxGapSeconds: Self.skinTempGapSeconds)
            .enumerated().map { Run(id: $0.offset, points: $0.element) }
        // Frame the data, not zero: skin temperature moves a degree or two, and an area fill (or an automatic
        // scale that includes zero) would flatten that into a strip at the top of a 0 to 40 axis.
        let values = points.map { shown($0.value) }
        let lo = values.min() ?? 32
        let hi = values.max() ?? 36
        let pad = max(0.4, (hi - lo) * 0.2)
        return Chart {
            ForEach(runs) { run in
                ForEach(run.points) { p in
                    LineMark(x: .value("Time", date(p.ts)),
                             y: .value("Skin temperature", shown(p.value)),
                             series: .value("Run", run.id))
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: span)
        .chartYScale(domain: (lo - pad) ... (hi + pad))
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis { xAxis }
    }

    private func spo2Chart(points: [KeyMetricReadings.BankedSeries.Point]) -> some View {
        // In-band readings are 70...100; frame the data without ever drawing above the physical ceiling.
        let low = max(70, (points.map(\.value).min() ?? 94).rounded(.down) - 3)
        return Chart {
            ForEach(points) { p in
                PointMark(x: .value("Time", date(p.ts)), y: .value("SpO₂", p.value))
                    .foregroundStyle(accent)
                    .symbolSize(points.count > 200 ? 16 : 28)
            }
        }
        .chartXScale(domain: span)
        .chartYScale(domain: low ... 101)
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis { xAxis }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: IntradaySeriesSection.axisTicks(in: span)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour())
        }
    }

    // MARK: Stats

    @ViewBuilder private var statsRow: some View {
        if let series = current?.series, series.count > 0 {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                stat(String(localized: "Readings"), series.count.formatted())
                if let lo = series.minValue { stat(String(localized: "Lowest"), display(lo)) }
                if let hi = series.maxValue { stat(String(localized: "Highest"), display(hi)) }
                Spacer(minLength: 0)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: Readings per hour

    private struct HourBin: Identifiable {
        let hourStart: Int
        let count: Int
        var id: Int { hourStart }
    }

    @ViewBuilder private var hourlySection: some View {
        let bins = KeyMetricReadings.hourlyCounts(current?.series.points ?? [])
            .map { HourBin(hourStart: $0.hourStart, count: $0.count) }
        if !bins.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Readings per hour").strandOverline()
                hourlyChart(bins)
                    .frame(height: 84)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Readings per hour"))
                    .accessibilityValue(Text("\(bins.map(\.count).reduce(0, +).formatted()) readings"))
            }
        }
    }

    @ViewBuilder private func hourlyChart(_ bins: [HourBin]) -> some View {
        let chart = Chart(bins) { bin in
            BarMark(x: .value("Hour", date(bin.hourStart), unit: .hour), y: .value("Readings", bin.count))
                .foregroundStyle(accent.opacity(0.75))
        }
        .chartXScale(domain: span)
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis { xAxis }
        if signal == .skinTemp {
            // A worn hour is one sample per second, so a full bar is 3,600 and a short one is an hour the strap
            // was off the wrist or had not synced.
            chart.chartYScale(domain: 0 ... Self.fullHourOfSamples)
        } else {
            chart
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch signal {
            case .skinTemp:
                Text("The strap takes a skin temperature every second while it is on your wrist. The line is 5-minute averages, and a gap means it was off your wrist or had not synced yet.")
            case .bloodOxygen:
                Text("Your strap measures SpO₂ only while you sleep, in short windows, so there are no readings while you are awake. These are the strap's own estimate and are not verified.")
                if let other = current?.series.statusBytes, other > 0 {
                    Text("The strap also wrote \(other.formatted()) other values in those windows that are status codes, not percentages. They are left out.")
                }
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var timelineLink: some View {
        NavigationLink {
            FullDayChartView(initialMetric: signal == .skinTemp ? .skinTemp : .spo2)
        } label: {
            HStack(spacing: 6) {
                Text("Open in Deep Timeline")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .font(StrandFont.subhead)
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
    }
}
