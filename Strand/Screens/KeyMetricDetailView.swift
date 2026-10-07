import SwiftUI
import StrandDesign

// KeyMetricDetailView.swift — the simplified drill-down for a key metric (`KeyMetricCatalog`; resting heart rate
// today). Exactly three things, top to bottom:
//
//   1. the latest MEASURED night's value and its date (no score, no ring),
//   2. one history chart with a range picker and scrubbing, where a night without a reading is a gap,
//   3. the server's explanation of what the measured nights show (`MetricInsightCard`).
//
// The value and the chart come from the phone's own data, through the same `Repository.exploreSeries` read the full
// dossier plots, so they draw the same whatever the explanation service does: it is optional, and a slow or failed
// explanation only ever changes its own card.

struct KeyMetricDetailView: View {
    let metric: MetricDescriptor
    let entry: KeyMetricCatalog.Entry

    @EnvironmentObject var repo: Repository
    @ObservedObject private var insights = MetricInsightStore.shared

    // The reader's unit preferences, exactly as `MetricDetailView` reads them (display only).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    @State private var range: ExploreRange = KeyMetricHistory.defaultRange
    /// Every measured night, ascending (`KeyMetricHistory.measuredNights` of the Explore series).
    @State private var nights: [KeyMetricHistory.Night] = []
    @State private var loaded = false
    /// The latest measured night of the last load. When a newer night arrives the explanation is asked for again.
    @State private var loadedLatestDay: String?
    @State private var insightRequest = 0

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func fmt(_ v: Double) -> String {
        metric.format(v, system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    private var displayUnit: String {
        metric.displayUnit(system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    private var accent: Color { metricAccent(metric) }
    private var domainTint: Color { metricDomain(metric).color }

    var body: some View {
        let insightState = insights.state(for: entry.insightMetric)
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                hero
                historyCard
                if insightState?.phase != .hidden {
                    MetricInsightCard(state: insightState, tint: domainTint, latestMeasuredDay: nights.last?.day)
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
        .navigationTitle(metric.title)
        .task(id: "\(metric.id)|\(repo.refreshSeq)") { await load() }
        // The explanation is asked for on appear, again when a newer night lands, and again for the next account
        // after one ends (`epoch`); leaving the screen cancels the request and its polling.
        .task(id: "\(insightRequest)|\(insights.epoch)") { await insights.refresh(entry.insightMetric) }
    }

    // MARK: Load

    /// The metric's own series only: the same `exploreSeries` read the full dossier plots (imported nights win over
    /// computed ones per day), with missing, zero and non-finite nights left out.
    private func load() async {
        let series = await repo.exploreSeries(key: metric.key, source: metric.source)
        guard !Task.isCancelled else { return }
        let measured = KeyMetricHistory.measuredNights(series)
        let latestDay = measured.last?.day
        if loaded, latestDay != loadedLatestDay { insightRequest &+= 1 }
        loadedLatestDay = latestDay
        nights = measured
        loaded = true
    }

    // MARK: 1. Latest measured value

    private var hero: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Latest measured night").strandOverline()
            if let latest = nights.last {
                let parts = KeyMetricHistory.splitUnit(fmt(latest.value), unit: displayUnit)
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
                Text(KeyMetricDates.night(latest.date))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else if loaded {
                Text("—")
                    .font(StrandFont.number(54))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("No measured nights yet")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text("Reading your nights…")
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

    private var historyCard: some View {
        let span = KeyMetricHistory.spanDays(nights)
        let hasHistory = loaded && !nights.isEmpty
        let isUnlocked: (ExploreRange) -> Bool = {
            KeyMetricHistory.isUnlocked($0, spanDays: span, hasHistory: hasHistory)
        }
        // A locked selection renders as the largest unlocked range below it without overwriting the choice (#943).
        let shown = ExploreRangeGating.coerced(selection: range, isUnlocked: isUnlocked)
        let domain = KeyMetricHistory.domain(nights, range: shown)
        let window = KeyMetricHistory.window(nights, domain: domain)
        return NoopCard(tint: domainTint) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("History")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                SegmentedPillControl(KeyMetricHistory.ranges,
                                     selection: Binding(get: { shown }, set: { range = $0 }),
                                     adaptsToAvailableWidth: true,
                                     isEnabled: isUnlocked) { $0.label }
                if let domain, !window.isEmpty {
                    KeyMetricHistoryChart(nights: window, domain: domain, tint: accent, format: fmt,
                                          metricTitle: metric.title)
                } else {
                    Group {
                        if loaded {
                            Text("No measured nights to chart yet.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textTertiary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
                if hasHistory, !KeyMetricHistory.ranges.allSatisfy(isUnlocked) {
                    Text("Longer ranges unlock as more history builds.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
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
#endif
