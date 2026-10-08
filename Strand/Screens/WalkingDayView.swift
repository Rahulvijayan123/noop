import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Walking quality for one day
//
// Opened from the Heart rate day page. The day's walks as the server's gait model read them from the strap's
// raw motion: each walk on the day's clock axis at the cadence it was walked, the day's totals, and the gait
// numbers (cadence, speed, stride, evenness). The reading is the one the Heart rate page already loaded; the
// page loads it itself (`DayCloudReadings.walking`) only when opened before that load finished.

struct WalkingDayView: View {
    let dayStart: Date

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceRaw = ""
    @State private var reading: WalkingDayReading?
    @State private var loaded: Bool
    @State private var selected: Date?

    init(dayStart: Date, reading: WalkingDayReading?, loaded: Bool) {
        self.dayStart = dayStart
        _reading = State(initialValue: reading)
        _loaded = State(initialValue: loaded)
    }

    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceRaw)
    }

    private var window: ClosedRange<Date> {
        dayStart...(Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400))
    }

    private var bouts: [WalkingDayReading.Bout] { reading?.bouts ?? [] }

    private var chartState: ChartState {
        if !loaded { return .loading }
        guard let reading else { return .empty(String(localized: "No gait reading for this day yet")) }
        return reading.bouts.isEmpty ? .empty(String(localized: "No walks detected")) : .ready
    }

    var body: some View {
        ScreenScaffold(title: "Walking quality", titleDisplay: .navigationBar, isLoading: !loaded) {
            ValueReadout(readout, isScrubbing: selected != nil, isLoading: !loaded)
            NoopCard {
                WalkingBoutsChart(bouts: bouts, window: window, state: chartState, selection: $selected)
            }
            StatGrid([
                StatItem(String(localized: "Walking"), value: reading.flatMap { $0.isEmpty ? nil : StretchFormat.duration($0.walkingSeconds) }),
                StatItem(String(localized: "Steps"), value: reading?.steps.map { Int($0.rounded()).formatted() }),
                StatItem(String(localized: "Brisk"), value: reading.flatMap { $0.briskSeconds > 0 ? StretchFormat.duration($0.briskSeconds) : nil }),
                StatItem(String(localized: "Walks"), value: bouts.isEmpty ? nil : "\(bouts.count)",
                         detail: bouts.map(\.seconds).max().map { String(localized: "Longest \(StretchFormat.duration($0))") }),
            ], columns: statColumns, isLoading: !loaded)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Gait")
                StatGrid([
                    StatItem(String(localized: "Cadence"), value: reading?.cadenceSpm.map { "\(Int($0.rounded()))" }, unit: "steps/min"),
                    StatItem(String(localized: "Speed"), value: reading?.speedMps.map(speedValue), unit: speedUnit),
                    StatItem(String(localized: "Stride"), value: reading?.strideM.map { UnitFormatter.distanceFromMeters($0, system: system) }),
                    StatItem(String(localized: "Step evenness"), value: reading?.regularity.map { "\(Int(($0 * 100).rounded()))" }, unit: "%"),
                ], columns: statColumns, isLoading: !loaded)
            }
            AboutDisclosure("About walking quality", paragraphs: [
                String(localized: "Read from the strap's raw motion every few seconds by a gait model, once the server has processed a raw motion session from your strap."),
                String(localized: "Each bar is one walk of a minute or more, as tall as its cadence. Brisk is 100 steps a minute or more, the usual moderate-intensity threshold for adults."),
                String(localized: "Steps, speed and stride are wrist estimates; they are steadiest on longer, unhurried walks."),
            ])
        }
        .task(id: dayStart) {
            guard !loaded else { return }
            await load()
        }
    }

    private var statColumns: Int {
        #if os(macOS)
        return 4
        #else
        return 2
        #endif
    }

    private func load() async {
        defer { loaded = true }
        reading = await DayCloudReadings.walking(dayStart: dayStart)
    }

    // MARK: Readout

    private var selectedBout: WalkingDayReading.Bout? {
        guard let selected else { return nil }
        return bouts.min { abs(WalkingBoutsChart.mid($0).timeIntervalSince(selected)) < abs(WalkingBoutsChart.mid($1).timeIntervalSince(selected)) }
    }

    private var readout: ReadoutContent {
        if let bout = selectedBout {
            let start = Date(timeIntervalSince1970: TimeInterval(bout.start))
            let context = [StretchFormat.duration(bout.seconds),
                           String(localized: "\(Int(bout.steps.rounded()).formatted()) steps"),
                           WalkingLane.isBrisk(bout) ? String(localized: "Brisk") : nil].compactMap { $0 }
            return ReadoutContent(dateLine: ReadoutContent.dateLine(start, period: .time),
                                  value: bout.cadenceSpm.map { "\(Int($0.rounded()))" }, unit: "steps/min",
                                  context: context.joined(separator: " · "))
        }
        return ReadoutContent(dateLine: ReadoutContent.dateLine(dayStart, period: .day),
                              value: reading?.cadenceSpm.map { "\(Int($0.rounded()))" }, unit: "steps/min",
                              context: reading?.cadenceSpm == nil ? nil : String(localized: "Average cadence"))
    }

    private var speedUnit: String { system == .imperial ? "mph" : "km/h" }

    private func speedValue(_ mps: Double) -> String {
        system == .imperial ? String(format: "%.1f", mps * 2.236_94) : String(format: "%.1f", mps * 3.6)
    }
}

// MARK: - Walks on the day's axis

/// Each walk as a bar from its start to its end on a clock axis, as tall as its cadence, against the brisk
/// threshold. Scrubbing selects the nearest walk.
struct WalkingBoutsChart: View {
    let bouts: [WalkingDayReading.Bout]
    let window: ClosedRange<Date>
    let state: ChartState
    @Binding var selection: Date?

    static func mid(_ bout: WalkingDayReading.Bout) -> Date {
        Date(timeIntervalSince1970: TimeInterval(bout.start + bout.end) / 2)
    }

    private static let axis = ChartValueAxis(unit: "steps/min", domain: .fitted(minSpan: 60, includeZero: true))

    var body: some View {
        let height = NoopMetrics.chartHeightSecondary + NaraChartStyle.legendHeight + NaraChartStyle.legendSpacing
        Group {
            switch state {
            case .loading:
                ChartPlaceholder(height: height)
            case .empty(let message):
                EmptyChartMessage(message, height: height)
            case .ready:
                VStack(alignment: .leading, spacing: NaraChartStyle.legendSpacing) {
                    chart.frame(height: NoopMetrics.chartHeightSecondary)
                    ChartLegend([ChartLegendItem(.swatch(ActivityFamily.walking.color), String(localized: "Brisk")),
                                 ChartLegendItem(.swatch(ActivityFamily.walking.color.opacity(0.45)), String(localized: "Slower"))])
                }
            }
        }
    }

    private var chart: some View {
        let cadences = bouts.compactMap(\.cadenceSpm) + [WalkingDayReading.briskCadenceSpm]
        let yLayout = Self.axis.layout(for: cadences)
        let xs = bouts.map(Self.mid)
        let selectedMid = selection.flatMap { ChartSelection.nearest(to: $0, in: xs) }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        return Chart {
            RuleMark(y: .value("Brisk", WalkingDayReading.briskCadenceSpm))
                .lineStyle(NaraChartStyle.reference)
                .foregroundStyle(NaraChartStyle.referenceColor)
            ForEach(bouts) { bout in
                let mid = Self.mid(bout)
                let half = max(Double(bout.seconds) / 2, span * 0.003)
                RectangleMark(xStart: .value("Start", mid.addingTimeInterval(-half)),
                              xEnd: .value("End", mid.addingTimeInterval(half)),
                              yStart: .value("Zero", 0),
                              yEnd: .value("Cadence", bout.cadenceSpm ?? 0))
                    .cornerRadius(NaraChartStyle.barCornerRadius)
                    .foregroundStyle(ActivityFamily.walking.color.opacity(WalkingLane.isBrisk(bout) ? 1 : 0.45))
                    .opacity(selectedMid == nil || selectedMid == mid ? 1 : NaraChartStyle.dimmedOpacity)
            }
            SelectionRule(selectedMid, unit: nil)
        }
        .naraChartAxes(x: ChartAxis.layout(window, style: .hours), y: yLayout)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Walks"))
        .accessibilityValue(Text(selectedMid.flatMap { mid in bouts.first { Self.mid($0) == mid } }.map {
            "\(StretchFormat.clock(Date(timeIntervalSince1970: TimeInterval($0.start)))), \(StretchFormat.duration($0.seconds)), \(Int(($0.cadenceSpm ?? 0).rounded())) steps/min"
        } ?? String(localized: "\(bouts.count) walks across the day")))
    }
}
