import SwiftUI
import StrandDesign
import StrandAnalytics

// KeyMetricDetailView.swift — the simplified drill-down for a key metric (`KeyMetricCatalog`: the strap's resting
// heart rate, HRV, wrist temperature, respiratory rate, blood oxygen, stable awake heart rate, steps and calories).
// Exactly three things, top to bottom:
//
//   1. the latest MEASURED night's or full day's value and its date (no score, no ring), labelled when it is an
//      estimate,
//   2. one history chart with a range picker and scrubbing, where a night or day without a reading is a gap,
//   3. the server's explanation of what the measured nights or days show (`MetricInsightCard`).
//
// HRV puts an RMSSD / SDNN switch above them, and each side is its own value, chart and explanation. Steps ends
// with one row that opens the Steps page's "How you walked" card on a page of its own.
//
// The value and the chart come from the phone's own data, each metric through its `KeyMetricSeries` (stable awake
// heart rate through the server's context history, which the phone does not store), so they draw the same
// whatever the explanation service does: it is optional, and a slow or failed explanation only ever changes its
// own card.

struct KeyMetricDetailView: View {
    let metric: MetricDescriptor
    let entry: KeyMetricCatalog.Entry

    @EnvironmentObject var repo: Repository
    @ObservedObject private var insights = MetricInsightStore.shared
    /// The context history stable awake heart rate is read from. Its `epoch` moves when the account, or the device
    /// ids the server holds the strap under, change; the screen then reads again.
    @ObservedObject private var context = PhysiologyContextStore.shared

    // The reader's unit preferences, exactly as `MetricDetailView` reads them (display only).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    /// The switch side the reader picked; nil shows the entry's first.
    @State private var picked: MetricInsightMetric?
    @State private var range: ExploreRange = KeyMetricHistory.defaultRange
    /// Every measured night or day of each side, ascending (`KeyMetricHistory.measured` of its series).
    @State private var readings: [MetricInsightMetric: [KeyMetricHistory.Reading]] = [:]
    @State private var loaded = false
    /// Each side's latest reading at the last load. When a newer one arrives the explanation is asked for again.
    @State private var loadedLatestDays: [MetricInsightMetric: String] = [:]
    @State private var insightRequest = 0

    /// The side on screen.
    private var side: MetricInsightMetric { picked ?? entry.metrics.first ?? .restingHeartRate }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    private func formatter(_ side: MetricInsightMetric) -> KeyMetricFormatter {
        KeyMetricFormatter(metric: side, descriptor: metric, system: unitSystem, temperature: temperatureUnit)
    }

    /// The chart's name for VoiceOver: the screen's title, and the side's on a switch.
    private func chartTitle(_ side: MetricInsightMetric) -> String {
        entry.metrics.count > 1 ? "\(entry.title), \(side.switchLabel)" : entry.title
    }

    private var accent: Color { metricAccent(metric) }
    private var domainTint: Color { metricDomain(metric).color }

    var body: some View {
        let side = self.side
        let shown = readings[side] ?? []
        let insightState = insights.state(for: side)
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if entry.metrics.count > 1 { sideSwitch }
                hero(side, shown: shown)
                historyCard(side, shown: shown)
                if insightState?.phase != .hidden {
                    MetricInsightCard(state: insightState, tint: domainTint, latestMeasuredDay: shown.last?.day,
                                      period: side.period)
                }
                // The gait model runs on the server, so the row is offered only where there is one.
                if side == .steps, let day = shown.last?.day, CloudPushSettings.isEnabled, CloudPushSettings.isConfigured {
                    walkingLink(day: day)
                }
            }
            .padding(NoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // Same horizontal-bounce guard as `MetricDetailView` (#697): this screen builds its own ScrollView.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .modifier(MetricDetailBackdrop())
        .navigationTitle(entry.title)
        // Read again on new data, a new account or read ids (the context epoch), and a new local day: a day metric's
        // latest full day moves at midnight.
        .task(id: "\(metric.id)|\(repo.refreshSeq)|\(context.epoch)|\(Repository.localDayKey(Date()))") {
            await load()
        }
        // The explanation is asked for on appear, for each side the switch shows, again when a newer night or day
        // lands, and again for the next account after one ends (`epoch`); leaving the screen cancels the request and
        // its polling.
        .task(id: "\(side.rawValue)|\(insightRequest)|\(insights.epoch)") { await insights.refresh(side) }
    }

    // MARK: Load

    /// Each side's own series (`KeyMetricSeries`), with missing, placeholder and non-finite values left out, and for
    /// a day metric only the complete local days (`KeyMetricHistory.measured(_:for:today:)`).
    private func load() async {
        let today = Repository.localDayKey(Date())
        var loadedReadings: [MetricInsightMetric: [KeyMetricHistory.Reading]] = [:]
        for side in entry.metrics {
            let series = await series(side, today: today)
            guard !Task.isCancelled else { return }
            loadedReadings[side] = KeyMetricHistory.measured(series, for: side, today: today)
        }
        let latestDays = loadedReadings.compactMapValues { $0.last?.day }
        if loaded, latestDays != loadedLatestDays { insightRequest &+= 1 }
        loadedLatestDays = latestDays
        readings = loadedReadings
        loaded = true
    }

    /// One side's whole series, unfiltered (docs/METRIC_INSIGHTS.md, "value the screen shows").
    private func series(_ side: MetricInsightMetric, today: String) async -> [(day: String, value: Double)] {
        switch side.series {
        case .explore:
            return await repo.exploreSeries(key: metric.key, source: metric.source)
        case .sdnn:
            return KeyMetricValues.sdnn(repo.days)
        case .absoluteSkinTemp:
            return KeyMetricValues.absoluteSkinTemp(repo.days)
        case .spo2WithCandidate:
            let measured = await repo.exploreSeries(key: metric.key, source: metric.source)
            // The descriptor is the strap's own (`KeyMetricCatalog`), the only one with a candidate behind it.
            guard PuffinExperiment.spo2CandidateDisplayEnabled else { return measured }
            let candidate = await repo.exploreSeries(key: "spo2_candidate", source: metric.source)
            return KeyMetricValues.filling(measured, from: candidate)
        case .contextHistory(let seriesKey):
            return await contextSeries(side, seriesKey: seriesKey, today: today)
        case .resolved:
            return await repo.resolvedSeries(key: metric.key, source: metric.source).values
        }
    }

    /// The daily values of `seriesKey` from the server's context history, through yesterday (the latest complete
    /// day), read with the running account's own credential (`PhysiologyContextStore.runningAccountRepository`).
    /// The phone's copy of the same reads draws first; then the server's answer replaces it, and a read the server
    /// does not answer keeps its copy. Local-only, signed out, an older server or no context give nothing: the
    /// screen's own empty state.
    ///
    /// Read here rather than through `PhysiologyContextStore.loadHistory`, which returns at once while the same
    /// range is in flight: a load that restarts mid-read would then find nothing and stay empty.
    private func contextSeries(_ side: MetricInsightMetric, seriesKey: String,
                               today: String) async -> [(day: String, value: Double)] {
        guard CloudPushSettings.isEnabled, CloudPushSettings.isConfigured,
              let scope = CloudPushRuntime.shared.runningScope,
              let repository = PhysiologyContextStore.runningAccountRepository(),
              let lastDay = PhysiologyContextDates.key(today, minusDays: 1) else { return [] }
        let candidates = context.readCandidates
        let reads = KeyMetricValues.contextReads(through: lastDay)
        // An answer read for one account never lands on the next one's screen.
        func current() -> Bool { !Task.isCancelled && CloudPushRuntime.shared.runningScope == scope }

        var copies: [[PhysiologyContext.DailyValue]] = []
        for read in reads {
            let cached = await repository.cachedHistory(from: read.from, to: read.to, deviceIds: candidates,
                                                        mode: read.mode)
            copies.append(cached?.dailyValues ?? [])
        }
        guard current() else { return [] }
        if readings[side] == nil {
            let instant = KeyMetricHistory.measured(KeyMetricValues.contextDaily(copies.flatMap { $0 },
                                                                                 seriesKey: seriesKey),
                                                    for: side, today: today)
            if !instant.isEmpty { readings[side] = instant }
        }

        var values: [PhysiologyContext.DailyValue] = []
        for (read, copy) in zip(reads, copies) {
            let answer = try? await repository.history(from: read.from, to: read.to, deviceIds: candidates,
                                                       mode: read.mode)
            guard current() else { return [] }
            if case .loaded(let history)? = answer { values += history.dailyValues } else { values += copy }
        }
        return KeyMetricValues.contextDaily(values, seriesKey: seriesKey)
    }

    // MARK: Switch

    /// RMSSD | SDNN. Each side has its own value, chart and explanation; the range carries over.
    private var sideSwitch: some View {
        SegmentedPillControl(entry.metrics, selection: Binding(get: { side }, set: { picked = $0 }),
                             fillsAvailableWidth: true) { $0.switchLabel }
    }

    // MARK: 1. Latest measured value

    private func hero(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                Text(KeyMetricCopy.latest(side.period)).strandOverline()
                Spacer(minLength: NoopMetrics.space2)
                if let label = side.measurement.label {
                    StatePill("\(label)", tone: .warning, showsDot: false)
                }
            }
            if let latest = shown.last {
                let parts = formatter(side).parts(latest.value)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.number)
                        .font(StrandFont.number(54))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let unit = parts.unit {
                        Text(unit)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(KeyMetricDates.long(latest.date))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else if loaded {
                Text("—")
                    .font(StrandFont.number(54))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(KeyMetricCopy.noneYet(side.period))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text(KeyMetricCopy.reading(side.period))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(minHeight: 64, alignment: .leading)
            }
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            NoopPanelSurface(tint: domainTint, cornerRadius: NoopMetrics.cardRadius, elevated: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 2. History

    private func historyCard(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading]) -> some View {
        let ranges = KeyMetricHistory.ranges(historyDays: side.historyDays)
        let span = KeyMetricHistory.spanDays(shown)
        let hasHistory = loaded && !shown.isEmpty
        let isUnlocked: (ExploreRange) -> Bool = {
            KeyMetricHistory.isUnlocked($0, spanDays: span, hasHistory: hasHistory, among: ranges)
        }
        // A locked selection renders as the largest unlocked range below it without overwriting the choice (#943).
        let selection = ExploreRangeGating.coerced(selection: range, isUnlocked: isUnlocked)
        let domain = KeyMetricHistory.domain(shown, range: selection)
        let window = KeyMetricHistory.window(shown, domain: domain)
        let format = formatter(side)
        return NoopCard(tint: domainTint) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("History")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                SegmentedPillControl(ranges,
                                     selection: Binding(get: { selection }, set: { range = $0 }),
                                     adaptsToAvailableWidth: true,
                                     isEnabled: isUnlocked) { $0.label }
                if let domain, !window.isEmpty {
                    KeyMetricHistoryChart(readings: window, domain: domain, tint: accent, format: format.text,
                                          plotValue: format.plotted, minimumPad: side.minimumPad,
                                          period: side.period, metricTitle: chartTitle(side))
                } else {
                    Group {
                        if loaded {
                            Text(KeyMetricCopy.nothingToChart(side.period))
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textTertiary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
                if hasHistory, !ranges.allSatisfy(isUnlocked) {
                    Text("Longer ranges unlock as more history builds.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: Walking

    /// The Steps page's "How you walked" card, one tap away instead of inline: it brings its own day stepper, an
    /// hourly chart and a list of walks, which would put a second chart and a second date on a screen built around
    /// one of each. It opens on the day the headline shows.
    private func walkingLink(day: String) -> some View {
        NavigationLink {
            WalkingDetailScreen(day: day)
        } label: {
            NoopCard(tint: domainTint) {
                HStack(spacing: 14) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ActivityFamily.walking.color)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How you walked")
                            .font(StrandFont.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Walking time, pace and each walk, from your strap's motion.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(LiquidPressStyle())
    }
}

/// The Steps page's "How you walked" card on a page of its own, opened from the key-metric Steps screen.
private struct WalkingDetailScreen: View {
    /// The local calendar day (`yyyy-MM-dd`) to open on.
    let day: String

    var body: some View {
        ScrollView {
            WalkingInsightsSection(day: day)
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .modifier(MetricDetailBackdrop())
        .navigationTitle(Text("Walking"))
    }
}

// MARK: - Backdrop

/// The metric detail screens' backdrop (#430 parity): the SAME backdrop as the screen that pushed them — the day-cycle
/// sky when the setting is on (full-viewport with the softer settle when "Sky behind cards" is also on, so the
/// transparent cards reveal it the whole way down), the custom background image when one is set, the plain canvas
/// otherwise. Shared by `MetricDetailView` and `KeyMetricDetailView`; same keys TodayView / LiquidTodayView gate on.
struct MetricDetailBackdrop: ViewModifier {
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    /// Custom background image (#custom-background): when active it overrides the sky.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    StrandPalette.surfaceBase
                    if backgroundStore.isActive {
                        BackgroundImageBackdrop()
                    } else if showDayCycleBackground {
                        LiquidSkyStatic(hour: nil, settleStrength: skyBehindCards ? 0.78 : 1)
                            .frame(maxWidth: .infinity)
                            .frame(height: skyBehindCards ? nil : 240, alignment: .top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Key metric — resting HR") {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    let metric = MetricCatalog.metric(key: "rhr", source: "my-whoop")!
    return NavigationStack {
        KeyMetricDetailView(metric: metric, entry: KeyMetricCatalog.entry(for: metric)!)
    }
    .environmentObject(repo)
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}

#Preview("Key metric — HRV switch") {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    let metric = MetricCatalog.metric(key: "hrv", source: "my-whoop")!
    return NavigationStack {
        KeyMetricDetailView(metric: metric, entry: KeyMetricCatalog.entry(for: metric)!)
    }
    .environmentObject(repo)
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}
#endif
