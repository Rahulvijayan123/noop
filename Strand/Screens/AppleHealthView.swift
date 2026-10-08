import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Apple Health (per-source page) — locked component system
//
// Vitaltrends-style, instrument-grade, uniform. ONE range control at the top
// (SegmentedPillControl), a LazyVGrid of fixed-height StatTiles (every metric the
// same 104pt tall), then ChartCard sections — Heart & Vitals, Activity & Energy,
// Body Composition, Sleep — each chart the same height with an avg/min/max footer.
//
// Everything reads from the "apple-health" source. ALL history is loaded once; the
// range control simply windows it client-side, RELATIVE TO THE LATEST data point
// (not "now"). Per the data contract a series may be SPARSE (weight/body-fat are
// weekly): if the selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay
// visibly distinct); only when it holds ZERO points do we auto-expand to the smallest
// larger range that does. Tile heroes show the LATEST point with "as of <date>".

/// #833/v7.7.2 (Apple Health per-source freeze): the snapshot AppleHealthView.load() builds, parked on the
/// long-lived Repository so a re-mount (macOS keys the NavigationSplitView detail with `.id`, so every sidebar
/// switch cold-mounts the screen) can RESTORE it in-memory instead of re-running the whole apple-health history
/// read on the @MainActor. The exact twin of `InsightsLoadCache` for #833; holds load()'s three `@State`
/// outputs. Consumed only when the seq AND the dayKey still match (see `Repository.appleHealthLoadedSeq` /
/// `appleHealthLoadedDayKey`).
struct AppleHealthLoadCache {
    let appleRows: [AppleDaily]
    let workoutCount: Int
    let series: [String: [(day: String, value: Double)]]
}

/// #833/v7.7.2: `.task(id:)` key for the Apple Health load, the data-refresh seq PLUS today's local day-key, so
/// the load re-runs both on a data change AND on a calendar-day rollover while the screen stays mounted across
/// midnight (keying on `refreshSeq` alone left the inside-load dayKey guard unreachable). The exact twin of
/// InsightsView's `InsightsLoadKey`.
struct AppleHealthLoadKey: Equatable {
    let seq: Int
    let dayKey: String
}

struct AppleHealthView: View {
    @EnvironmentObject var repo: Repository

    // iOS-only: the live two-way HealthKit bridge, injected at StrandiOSApp. macOS has no HealthKit
    // (HealthKitBridge is `#if os(iOS)` in its own file and isn't in the macOS environment), so this
    // property and every `health.*` use below MUST stay inside `#if os(iOS)`.
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var model: AppModel
    #endif

    // Imperial/Metric display preference (D#103). Weight and lean mass (stored kg) re-label to lb here;
    // every other Apple Health metric is unit-agnostic. Display-only.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .imperial }
    /// kg value → the active mass unit, full string with label (e.g. "74.5 kg" / "164.2 lb").
    private func massLabel(_ kg: Double) -> String { UnitFormatter.massFromKilograms(kg, system: unitSystem) }

    /// Optional pre-seeded data for previews; when set, the async store load is
    /// skipped (store-backed reads can't be seeded in a preview). Production leaves
    /// this nil and loads from the repository in `.task`.
    private let previewData: PreviewData?

    init() { self.previewData = nil }
    fileprivate init(previewData: PreviewData) { self.previewData = previewData }

    // Loaded state.
    @State private var loaded = false
    @State private var appleRows: [AppleDaily] = []
    @State private var workoutCount = 0

    // Raw series (day, value) keyed by metric — ALL history, ascending by day.
    @State private var series: [String: [(day: String, value: Double)]] = [:]

    // The series keys this page pulls from the apple-health source.
    private static let seriesKeys = [
        "steps", "active_kcal", "vo2max",
        "resting_hr", "hrv", "spo2", "resp_rate", "asleep_min",
        "weight", "body_fat", "lean_mass", "bmi"
    ]

    private static let source = "apple-health"

    var body: some View {
        MorePaneNavigation {
            ScreenScaffold(title: "Apple Health", dateLine: spanLine, titleDisplay: .navigationBar,
                           onRefresh: { await repo.refresh() }) {
                #if os(iOS)
                liveSyncCard
                #endif
                if loaded && !hasAnyData {
                    emptyNote
                } else {
                    latestSections
                        .loadingRedaction(!loaded)
                        .background { if !loaded { LoadingAccessibilityElement() } }
                }
                AboutDisclosure("About Apple Health", paragraphs: aboutParagraphs)
            }
        }
        .task(id: AppleHealthLoadKey(seq: repo.refreshSeq, dayKey: Repository.localDayKey(Date()))) { await load(allowCache: true) }
    }

    /// True if ANY series or per-day row holds data (drives the empty state).
    private var hasAnyData: Bool {
        if !appleRows.isEmpty { return true }
        return series.values.contains { !$0.isEmpty }
    }

    // MARK: - Load

    private func load(allowCache: Bool = false) async {
        // Previews inject data directly (store-backed reads can't be seeded). Stays ABOVE the cache path so a
        // preview never touches the repo.
        if let pd = previewData {
            appleRows = pd.rows.sorted { $0.day < $1.day }
            workoutCount = pd.workoutCount
            series = pd.series
            loaded = true
            return
        }

        // #833/v7.7.2: the whole heavy load, cache short-circuit, DEBUG fire tally, and write-back live on the
        // long-lived repo (`performAppleHealthLoad`, a headless-testable seam) so a re-mount RESTORES the prior
        // snapshot in-memory instead of re-running the whole apple-health history read on the @MainActor, which
        // is the freeze fix. `allowCache` is true ONLY on the `.task(id:)`-driven path (a re-mount / data refresh
        // / day rollover); the direct load() sites (Enable / Sync now) leave it false so a live sync always
        // re-reads. The seam owns the cache; this view just copies the snapshot into its `@State`.
        let snapshot = await repo.performAppleHealthLoad(seriesKeys: Self.seriesKeys, allowCache: allowCache)
        appleRows = snapshot.appleRows
        workoutCount = snapshot.workoutCount
        series = snapshot.series
        loaded = true
    }

    /// The span the imported days cover ("12 Mar 2019 – 6 Oct 2026"), data only.
    private var spanLine: String? {
        guard loaded else { return nil }
        let days = (appleRows.map(\.day) + series.values.flatMap { $0.map(\.day) })
        guard let first = days.min(), let last = days.max(),
              let lo = ChartDay.date(forKey: first), let hi = ChartDay.date(forKey: last) else { return nil }
        let a = lo.formatted(.dateTime.day().month(.abbreviated).year())
        let b = hi.formatted(.dateTime.day().month(.abbreviated).year())
        return a == b ? a : "\(a) – \(b)"
    }

    // MARK: - Latest values

    /// One row per series: the latest reading and its date. A row opens that metric's own page, which draws the
    /// chart that suits it (bars for daily totals, points on a fixed scale for blood oxygen, sparse points for
    /// body composition).
    private var latestSections: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            NoopListSection("Heart") {
                seriesRow("resting_hr", icon: "heart", color: StrandPalette.metricRose, title: "Resting heart rate",
                          value: { "\(Int($0.rounded())) bpm" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("hrv", icon: "waveform.path.ecg", color: StrandPalette.metricPurple, title: "HRV (SDNN)",
                          value: { "\(Int($0.rounded())) ms" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("spo2", icon: "drop", color: StrandPalette.metricCyan, title: "Blood oxygen",
                          value: { "\(MoreFormat.compact($0)) %" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("resp_rate", icon: "lungs", color: StrandPalette.metricCyan, title: "Respiratory rate",
                          value: { "\(MoreFormat.oneDecimal($0)) rpm" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("vo2max", icon: "lungs.fill", color: StrandPalette.chargeColor, title: "VO₂ max",
                          value: { "\(MoreFormat.oneDecimal($0)) ml/kg/min" })
            }
            NoopListSection("Activity") {
                seriesRow("steps", icon: "figure.walk", color: StrandPalette.metricCyan, title: "Steps",
                          value: { "\(MoreFormat.integer($0)) steps" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("active_kcal", icon: "flame", color: StrandPalette.metricAmber, title: "Active energy",
                          value: { "\(MoreFormat.integer($0)) kcal" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                NoopListRow(icon: "figure.run", iconColor: StrandPalette.effortColor, title: "Workouts",
                            value: loaded ? "\(workoutCount)" : "00", showsChevron: false)
            }
            NoopListSection("Body") {
                seriesRow("weight", icon: "scalemass", color: StrandPalette.metricPurple, title: "Weight",
                          value: { massLabel($0) })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("body_fat", icon: "percent", color: StrandPalette.metricAmber, title: "Body fat",
                          value: { "\(MoreFormat.oneDecimal($0)) %" })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("lean_mass", icon: "figure.arms.open", color: StrandPalette.metricPurple, title: "Lean body mass",
                          value: { massLabel($0) })
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                seriesRow("bmi", icon: "figure", color: StrandPalette.metricPurple, title: "BMI",
                          value: { MoreFormat.oneDecimal($0) })
            }
            NoopListSection("Sleep") {
                seriesRow("asleep_min", icon: "moon.zzz", color: StrandPalette.restColor, title: "Asleep",
                          value: { MoreFormat.duration(minutes: $0) })
            }
        }
        .buttonStyle(.plain)
    }

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

    /// Catalogued Apple Health metrics open the shared metric page; the five the catalog has no Apple Health
    /// entry for open the per-source page, with the chart chosen for each.
    @ViewBuilder
    private func destination(_ key: String) -> some View {
        if let metric = MetricCatalog.metric(key: key, source: Self.source) {
            MetricDetailView(metric: metric)
        } else if let presentation = Self.sourcePresentation(key) {
            SourceSeriesDetailView(presentation: presentation, rows: series[key] ?? [], sourceName: "Apple Health")
        }
    }

    static func sourcePresentation(_ key: String) -> SourceSeriesPresentation? {
        switch key {
        case "resting_hr":
            return SourceSeriesPresentation(
                title: String(localized: "Resting heart rate"), unit: "bpm", color: StrandPalette.metricRose,
                chart: .vital(minSpan: 10, decimals: 0), format: { "\(Int($0.rounded()))" },
                about: [String(localized: "The resting heart rate Apple Health records each day, usually from your watch's readings while you are still. Nara's own resting heart rate from your strap is measured during sleep, so the two can differ by a few beats.")])
        case "hrv":
            return SourceSeriesPresentation(
                title: String(localized: "HRV (SDNN)"), unit: "ms", color: StrandPalette.metricPurple,
                chart: .vital(minSpan: 20, decimals: 0), format: { "\(Int($0.rounded()))" },
                about: [String(localized: "Apple Health stores heart rate variability as SDNN: the spread of the time between beats, from short readings taken through the day. Nara's HRV from your strap is RMSSD, measured during sleep, so the two are not directly comparable.")])
        case "spo2":
            return SourceSeriesPresentation(
                title: String(localized: "Blood oxygen"), unit: "%", color: StrandPalette.metricCyan,
                chart: .percent(domain: 85...100, reference: 95), format: { MoreFormat.compact($0) },
                about: [String(localized: "Blood oxygen saturation as Apple Health records it, usually from your watch's spot readings. Most healthy readings sit between 95 and 100 %. This is a wellness reading, not a medical measurement.")])
        case "resp_rate":
            return SourceSeriesPresentation(
                title: String(localized: "Respiratory rate"), unit: "rpm", color: StrandPalette.metricCyan,
                chart: .vital(minSpan: 3, decimals: 1), format: { MoreFormat.oneDecimal($0) },
                about: [String(localized: "Breaths per minute as Apple Health records it, usually measured while you sleep.")])
        case "asleep_min":
            return SourceSeriesPresentation(
                title: String(localized: "Asleep"), unit: nil, color: StrandPalette.restColor,
                chart: .duration, format: { MoreFormat.duration(minutes: $0) },
                about: [String(localized: "Time asleep each night as Apple Health records it, from your watch or another app that writes sleep to Health.")],
                nightly: true)
        default:
            return nil
        }
    }

    @ViewBuilder
    private var emptyNote: some View {
        #if os(iOS)
        // #348 — when the build can't carry the HealthKit entitlement there's no "Enable" button to tap, so the
        // empty-state copy points at the file path instead of a control that isn't shown.
        ComingSoon(what: health.auth == .entitlementMissing
                   ? "Nothing here yet. Import a Health export in Data sources to bring your Apple Health history in."
                   : "Nothing here yet. Turn on live sync above, or import a Health export in Data sources.")
        #else
        ComingSoon(what: "Nothing imported yet. On an iPhone: Health app, tap your photo, Export All Health Data, then import the .zip in Data sources.")
        #endif
    }

    private var aboutParagraphs: [String] {
        var out = [
            String(localized: "Everything on this page comes from Apple Health, read on \(Platform.deviceNounPhrase): live sync or an imported export. Each value is the latest reading and its date; open a row for its history."),
        ]
        #if os(iOS)
        out.append(String(localized: "With live sync on, Nara also writes your strap's data back to Health: sleep with its stages, continuous heart rate, workouts and nightly vitals."))
        if health.auth == .entitlementMissing {
            out.append(String(localized: "This install can't connect to Apple Health directly. It was signed with a profile that doesn't include Apple's Health permission, so there is nothing to enable and Nara won't appear under Settings › Health. Import a Health export in Data sources instead, or turn on Shortcuts Export to feed your strap data into Health. A build from the App Store or signed with a paid developer account connects directly."))
        }
        #endif
        return out
    }

    // MARK: - Live Apple Health (iOS only)
    //
    // The opt-in entry point for the two-way HealthKitBridge. macOS has no HealthKit, so this whole
    // card — and every `health.*` reference — is `#if os(iOS)`-gated. Tapping "Enable Apple Health"
    // shows the system permission sheet (rationale strings ship in the iOS target's Info.plist), then
    // runs the first read + write-back and refreshes this screen. Once authorized, a "Sync now"
    // control and last-synced/status line take its place.
    #if os(iOS)
    private var liveSyncWord: (LocalizedStringKey, StrandTone) {
        switch health.auth {
        case .authorized: return (health.syncing ? "Syncing" : "Connected", .positive)
        case .unknown, .denied: return ("Off", .neutral)
        case .entitlementMissing, .unavailable: return ("Unavailable", .neutral)
        }
    }

    @ViewBuilder
    private var liveSyncCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space3) {
                    Text("Live sync")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    StatePill(liveSyncWord.0, tone: liveSyncWord.1)
                }

                switch health.auth {
                case .unavailable:
                    Text("Apple Health isn't available on \(Platform.deviceNounPhrase).")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .entitlementMissing:
                    // #348 / #930: the sideload was re-signed WITHOUT the HealthKit entitlement, so "Enable Apple
                    // Health" can never work. One line here; the why and the way around it are in About.
                    Text("This install can't connect to Apple Health directly.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .unknown, .denied:
                    Text("Read your health data from Apple Health and write your strap's data back.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton("Enable Apple Health", systemImage: "heart", kind: .primary) {
                        Task {
                            await health.requestAuthorization()
                            await HealthSyncRefreshCoordinator.run(
                                sync: { await health.sync() },
                                refresh: {
                                    await model.refreshAfterAppleHealthSync(
                                        authorized: health.auth == .authorized)
                                }
                            )
                            await load()
                        }
                    }
                    if health.auth == .denied {
                        Text("If you don't see the prompt, turn on Nara in Settings › Health › Data Access & Devices.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .authorized:
                    HStack(spacing: NoopMetrics.space3) {
                        if let last = health.lastSync {
                            Text("Last synced \(relativeAgo(last.timeIntervalSince1970))")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: NoopMetrics.space2)
                        NoopButton("Sync now", systemImage: "arrow.triangle.2.circlepath", kind: .secondary) {
                            Task {
                                await HealthSyncRefreshCoordinator.run(
                                    sync: { await health.sync() },
                                    refresh: {
                                        await model.refreshAfterAppleHealthSync(
                                            authorized: health.auth == .authorized)
                                    }
                                )
                                await load()
                            }
                        }
                        .disabled(health.syncing)
                    }
                }

                if let err = health.lastError {
                    Text(err)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusCritical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    #endif
}

// MARK: - Preview seam

extension AppleHealthView {
    /// In-memory bundle that bypasses the store-backed async load for previews.
    fileprivate struct PreviewData {
        var rows: [AppleDaily]
        var workoutCount: Int
        var series: [String: [(day: String, value: Double)]]
    }
}

#if DEBUG
/// `--demo-screen applehealthrhr` (or `applehealthsleep`): the per-source page for an Apple Health series with
/// no catalog entry, on the seeded history (`--demo-sources`).
struct AppleHealthSeriesDemoScreen: View {
    let key: String
    @EnvironmentObject private var repo: Repository
    @State private var rows: [(day: String, value: Double)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let presentation = AppleHealthView.sourcePresentation(key) {
                SourceSeriesDetailView(presentation: presentation, rows: rows, sourceName: "Apple Health")
            } else {
                Color.clear
            }
        }
        .task {
            rows = await repo.series(key: key, source: "apple-health", days: 4000, fullHistory: true)
            loaded = true
        }
    }
}

@MainActor
private func appleHealthPreviewData() -> AppleHealthView.PreviewData {
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()

    var rows: [AppleDaily] = []
    var series: [String: [(day: String, value: Double)]] = [
        "steps": [], "active_kcal": [], "vo2max": [],
        "resting_hr": [], "hrv": [], "spo2": [], "resp_rate": [], "asleep_min": [],
        "weight": [], "body_fat": [], "lean_mass": [], "bmi": []
    ]

    // Seed ~2 years so the range control has real depth to window into.
    for i in stride(from: 729, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let day = fmt.string(from: d)
        let phase = Double(729 - i)
        let steps  = 8000 + 3200 * sin(phase / 6.0) + Double((Int(phase) * 53) % 1800)
        let active = 420 + 180 * sin(phase / 5.0 + 0.6) + Double((Int(phase) * 17) % 90)
        let rhr    = 53 + 4 * sin(phase / 8.0) + Double((Int(phase) * 7) % 4) - 2
        let hrv    = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let spo2   = 96 + 1.4 * sin(phase / 4.0) + Double((Int(phase) * 3) % 2)
        let resp   = 14.5 + 1.2 * sin(phase / 7.0)
        let vo2    = 47 + 2.2 * sin(phase / 21.0)
        let asleep = 410 + 55 * sin(phase / 5.0 + 1.1) + Double((Int(phase) * 11) % 30) - 15
        // Slow body-composition drift over the two years (measured WEEKLY → sparse).
        let weight = 78.0 - 5.0 * sin(phase / 220.0) + 0.6 * sin(phase / 13.0)
        let bodyFat = 18.0 - 3.0 * sin(phase / 240.0) + 0.4 * sin(phase / 11.0)
        let lean   = weight * (1.0 - bodyFat / 100.0)
        let bmi    = weight / (1.78 * 1.78)

        rows.append(AppleDaily(
            day: day,
            steps: Int(steps.rounded()),
            activeKcal: max(120, active),
            basalKcal: 1600,
            vo2max: vo2,
            avgHr: 72,
            maxHr: 148,
            walkingHr: 96,
            weightKg: weight))

        series["steps"]?.append((day, max(0, steps)))
        series["active_kcal"]?.append((day, max(80, active)))
        series["vo2max"]?.append((day, vo2))
        series["resting_hr"]?.append((day, max(40, rhr)))
        series["hrv"]?.append((day, max(15, hrv)))
        series["spo2"]?.append((day, min(100, spo2)))
        series["resp_rate"]?.append((day, resp))
        series["asleep_min"]?.append((day, max(180, asleep)))
        // Body composition is logged once a week → deliberately sparse, to exercise
        // the trailing-window → ALL fallback (a W/M view would otherwise be empty).
        if Int(phase) % 7 == 0 {
            series["weight"]?.append((day, weight))
            series["body_fat"]?.append((day, bodyFat))
            series["lean_mass"]?.append((day, lean))
            series["bmi"]?.append((day, bmi))
        }
    }

    return .init(rows: rows, workoutCount: 124, series: series)
}

#Preview("Apple Health — seeded") {
    AppleHealthView(previewData: appleHealthPreviewData())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}

#Preview("Apple Health — empty") {
    AppleHealthView(previewData: .init(rows: [], workoutCount: 0, series: [:]))
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 920, height: 600)
        .preferredColorScheme(.dark)
}
#endif
