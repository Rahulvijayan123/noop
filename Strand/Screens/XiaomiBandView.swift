import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Xiaomi Smart Band (Mi Band) — per-source page
//
// Everything here reads from the "xiaomi-band" source, the data imported from the Mi Fitness app in Data
// sources: the last night's sleep stages, then one row per series with its latest reading. A row opens that
// metric's own page (the shared metric page for catalogued keys, the per-source page for distance), which
// draws the chart that suits it; this page draws no trend charts of its own.

struct XiaomiBandView: View {
    @EnvironmentObject var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .imperial,
            override: distanceSystemRaw)
    }

    /// Per-source partition key — matches `XiaomiImporter.deviceId`.
    private static let source = "xiaomi-band"

    @State private var loaded = false
    @State private var series: [String: [(day: String, value: Double)]] = [:]
    /// Imported Mi sleep sessions (carry the per-epoch hypnogram in `stagesJSON`).
    @State private var sleeps: [CachedSleepSession] = []

    /// The metricSeries keys written by `XiaomiImporter`.
    private static let seriesKeys = [
        "steps", "distance_m", "energy_kcal", "intensity_min",
        "rhr", "avg_hr", "max_hr", "spo2",
        "sleep_total_min", "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "sleep_score",
        "stress", "vitality",
    ]

    var body: some View {
        MorePaneNavigation {
            ScreenScaffold(title: "Mi Band", dateLine: spanLine, titleDisplay: .navigationBar,
                           onRefresh: { await repo.refresh() }) {
                if loaded && !hasAnyData {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        ComingSoon(what: "Nothing imported yet")
                        NavigationLink {
                            DataSourcesView()
                        } label: {
                            Label("Open Data sources", systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(NoopButtonStyle(.secondary))
                    }
                } else {
                    if loaded {
                        sleepDetailSection
                    } else {
                        // Last night's card at its final size while the import loads, so the rows below
                        // do not move down when it lands.
                        lastNightPlaceholder
                    }
                    latestSections
                        .loadingRedaction(!loaded)
                        .background { if !loaded { LoadingAccessibilityElement() } }
                }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private var hasAnyData: Bool { series.values.contains { !$0.isEmpty } }

    // MARK: - Load

    private func load() async {
        var fetched: [String: [(day: String, value: Double)]] = [:]
        for key in Self.seriesKeys {
            fetched[key] = await repo.series(key: key, source: Self.source)
        }
        var loadedSleeps: [CachedSleepSession] = []
        if let store = await repo.storeHandle() {
            let far = Int(Date.distantFuture.timeIntervalSince1970)
            loadedSleeps = (try? await store.sleepSessions(deviceId: Self.source, from: 0, to: far, limit: 4000)) ?? []
        }
        await MainActor.run {
            series = fetched
            sleeps = loadedSleeps
            loaded = true
        }
    }

    /// The widest span across all loaded series, data only.
    private var spanLine: String? {
        let allDays = series.values.flatMap { $0 }.map(\.day)
        guard let first = allDays.min(), let last = allDays.max(),
              let lo = ChartDay.date(forKey: first), let hi = ChartDay.date(forKey: last) else { return nil }
        let a = lo.formatted(.dateTime.day().month(.abbreviated).year())
        let b = hi.formatted(.dateTime.day().month(.abbreviated).year())
        return a == b ? a : "\(a) – \(b)"
    }

    // MARK: - Last night (hypnogram)

    /// The most recent imported night that carries a per-epoch hypnogram, drawn with the same `Hypnogram` the
    /// Sleep screen uses, with the time in each stage under it. Absent when no Mi sleep has stages.
    @ViewBuilder
    private var sleepDetailSection: some View {
        if let night = sleeps.last(where: { ($0.stagesJSON?.count ?? 0) > 2 }),
           let decoded = decodeStages(night.stagesJSON, sessionStart: night.startTs),
           decoded.intervals.count >= 2 {
            let s = decoded.stages
            let start = Date(timeIntervalSince1970: TimeInterval(night.startTs))
            let wake = Date(timeIntervalSince1970: TimeInterval(night.endTs))
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last night", trailing: ReadoutContent.dateLine(wake, period: .night))
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                            Text(MoreFormat.duration(minutes: s.asleepMin))
                                .font(StrandFont.number(28))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("asleep")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer(minLength: 0)
                            if let eff = night.efficiency {
                                Text("\(Int(eff.rounded())) % efficiency")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Hypnogram(intervals: decoded.intervals,
                                  height: NoopMetrics.chartHeightSecondary,
                                  showsStageAxis: true,
                                  nightStart: start,
                                  showsTimeAxis: true)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.space3),
                                            GridItem(.flexible(), spacing: NoopMetrics.space3)],
                                  alignment: .leading, spacing: NoopMetrics.space2) {
                            stageLegend("Deep", s.deep, StrandPalette.sleepDeep)
                            stageLegend("REM", s.rem, StrandPalette.sleepREM)
                            stageLegend("Light", s.light, StrandPalette.sleepLight)
                            stageLegend("Awake", s.awake, StrandPalette.sleepAwake)
                        }
                    }
                }
            }
        }
    }

    private var lastNightPlaceholder: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last night", trailing: "Mon 00 – Tue 00 Sep")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text(verbatim: "0 h 00 m").font(StrandFont.number(28))
                    ChartPlaceholder(height: NoopMetrics.chartHeightSecondary)
                    Text(verbatim: "Deep 0 h 00 m · REM 0 h 00 m").font(StrandFont.footnote)
                    Text(verbatim: "Light 0 h 00 m · Awake 00 m").font(StrandFont.footnote)
                }
            }
        }
        .loadingPlaceholder(true)
    }

    private func stageLegend(_ name: LocalizedStringKey, _ minutes: Double, _ color: Color) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(name)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space1)
            Text(MoreFormat.duration(minutes: minutes))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private struct MiStages { var awake = 0.0; var light = 0.0; var deep = 0.0; var rem = 0.0
        var asleepMin: Double { light + deep + rem } }

    /// Reconstruct `[SleepInterval]` (seconds from onset) + stage totals from the verbatim
    /// `[{start,end,stage}]` hypnogram JSON the importer stores. Mirrors `SleepView.decodeSegments`.
    private func decodeStages(_ json: String?, sessionStart: Int) -> (stages: MiStages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !arr.isEmpty
        else { return nil }
        var stages = MiStages()
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let mins = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += mins
            case "light": stage = .light; stages.light += mins
            case "deep": stage = .deep; stages.deep += mins
            case "rem": stage = .rem; stages.rem += mins
            default: continue
            }
            intervals.append(SleepInterval(stage: stage,
                                           start: TimeInterval(start - sessionStart),
                                           end: TimeInterval(end - sessionStart)))
        }
        return stages.asleepMin > 0 ? (stages, intervals) : nil
    }

    // MARK: - Latest values

    private var latestSections: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            NoopListSection("Heart") {
                seriesRow("rhr", icon: "heart", color: StrandPalette.metricRose, title: "Resting heart rate",
                          value: { "\(Int($0.rounded())) bpm" })
                divider
                seriesRow("avg_hr", icon: "heart.text.square", color: StrandPalette.metricRose, title: "Average heart rate",
                          value: { "\(Int($0.rounded())) bpm" })
                divider
                seriesRow("max_hr", icon: "bolt.heart", color: StrandPalette.metricRose, title: "Peak heart rate",
                          value: { "\(Int($0.rounded())) bpm" })
                divider
                seriesRow("spo2", icon: "drop", color: StrandPalette.metricCyan, title: "Blood oxygen",
                          value: { "\(Int($0.rounded())) %" })
            }
            NoopListSection("Sleep") {
                seriesRow("sleep_total_min", icon: "moon.zzz", color: StrandPalette.restColor, title: "Time asleep",
                          value: { MoreFormat.duration(minutes: $0) })
                divider
                seriesRow("sleep_deep_min", icon: "moon.fill", color: StrandPalette.sleepDeep, title: "Deep sleep",
                          value: { MoreFormat.duration(minutes: $0) })
                divider
                seriesRow("sleep_rem_min", icon: "moon.haze", color: StrandPalette.sleepREM, title: "REM sleep",
                          value: { MoreFormat.duration(minutes: $0) })
                divider
                seriesRow("sleep_score", icon: "moon.stars", color: StrandPalette.restColor, title: "Sleep score",
                          value: { "\(Int($0.rounded()))" })
            }
            NoopListSection("Activity") {
                seriesRow("steps", icon: "figure.walk", color: StrandPalette.metricCyan, title: "Steps",
                          value: { "\(MoreFormat.integer($0)) steps" })
                divider
                seriesRow("distance_m", icon: "map", color: StrandPalette.metricCyan, title: "Distance",
                          value: { UnitFormatter.distanceFromMeters($0, system: distanceUnitSystem) })
                divider
                seriesRow("energy_kcal", icon: "flame", color: StrandPalette.metricAmber, title: "Active energy",
                          value: { "\(MoreFormat.integer($0)) kcal" })
                divider
                seriesRow("intensity_min", icon: "figure.run", color: StrandPalette.effortColor, title: "Intensity minutes",
                          value: { "\(Int($0.rounded())) min" })
            }
            NoopListSection("Wellbeing") {
                seriesRow("stress", icon: "gauge.with.dots.needle.50percent", color: StrandPalette.stressColor,
                          title: "Stress", value: { "\(Int($0.rounded())) / 100" })
                divider
                seriesRow("vitality", icon: "sparkles", color: StrandPalette.chargeColor, title: "Vitality",
                          value: { "\(Int($0.rounded()))" })
            }
        }
        .buttonStyle(.plain)
    }

    private var divider: some View { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }

    @ViewBuilder
    private func seriesRow(_ key: String, icon: String, color: Color, title: LocalizedStringKey,
                           value: @escaping (Double) -> String) -> some View {
        let rows = series[key] ?? []
        if let latest = rows.last {
            NavigationLink {
                destination(key)
            } label: {
                NoopListRow(icon: icon, iconColor: color, title: title, subtitle: MoreFormat.day(latest.day),
                            value: value(latest.value))
            }
        } else {
            NoopListRow(icon: icon, iconColor: color, title: title, subtitle: loaded ? nil : "Mon 00 Sep",
                        value: loaded ? "—" : "000", showsChevron: false)
        }
    }

    @ViewBuilder
    private func destination(_ key: String) -> some View {
        if let metric = MetricCatalog.metric(key: key, source: Self.source) {
            MetricDetailView(metric: metric)
        } else if key == "distance_m" {
            // Distance has no catalog entry: the per-source page, as daily bars in the reader's distance unit.
            let imperial = distanceUnitSystem == .imperial
            let perUnit = imperial ? 1609.344 : 1000.0
            SourceSeriesDetailView(
                presentation: SourceSeriesPresentation(
                    title: String(localized: "Distance"), unit: imperial ? "mi" : "km", color: StrandPalette.metricCyan,
                    chart: .totals(minSpan: 2, decimals: 1), format: { MoreFormat.oneDecimal($0) },
                    about: [String(localized: "The distance your Mi Band counted each day, as the Mi Fitness app exported it.")]),
                rows: (series[key] ?? []).map { ($0.day, $0.value / perUnit) },
                sourceName: "Mi Band")
        }
    }
}
