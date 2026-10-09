import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Health: a glance at the body's vital signs and the weekly fitness estimates, each a tile that opens
/// its own detail page, then the body-clock and cycle reads and the private records.
///
/// Built to the design system's top-level rule (docs/DESIGN_SYSTEM.md): values and one state word per
/// tile, no helper sentences, one About at the bottom. The depth moved one tap down: each tile's detail
/// page carries the history, the Fitness Age readiness checklist and the Vitality factors have their own
/// pages, and the body clock and cycle cards open from their rows. Live heart rate lives on the Live
/// screen and the Charge breakdown on the Charge detail, so neither is repeated here.
struct HealthView: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Health", titleDisplay: .navigationBar, isLoading: !repo.loaded,
                       onRefresh: { await repo.refresh() }) {
            // A real alert, so it leads when it is active; nothing at all otherwise.
            HealthAlertSection()
            if repo.loaded && repo.days.isEmpty {
                ComingSoon(what: "No biometrics yet. Import your WHOOP export (and Apple Health if you have it) in Data Sources to fill this in.")
            }
            VitalsSection()
            FitnessSection()
            RhythmsSection()
            HealthRecordsSection()
            AboutDisclosure(paragraphs: [
                String(localized: "Once Nara has 14 nights of history, in-range compares each vital to your own baseline (approximate, not medical advice); until then, typical adult ranges apply."),
            ])
        }
    }
}

// MARK: - Illness heads-up

/// The confounder-suppressed illness heads-up, only when the engine returned a non-quiet level.
private struct HealthAlertSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let illness = model.illnessSignal, illness.level != .quiet {
            HeadsUpCard(result: illness, distance: model.illnessDistance)
        }
    }
}

// MARK: - Vitals grid

/// The vital signs as tiles: the latest value, one state word and the last nights' trend, each opening
/// the metric's detail page. Depends only on `repo`, so a live HR tick never re-renders it.
private struct VitalsSection: View {
    @EnvironmentObject var repo: Repository

    // Temperature display preference (D#103). Skin temp is stored in °C (absolute or a ±deviation); the
    // toggle re-labels it to °F. Display-only — banding still runs on the stored °C value.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""   // #1846
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .imperial
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }

    // #103/queue-11a: SpO₂ candidate nightly means from metricSeries — WHOOP `spo2_candidate_82`, or an
    // Oura owner's ceiling@100 `0x6F` mean (device-conditional, see IntelligenceEngine) — loaded when
    // the experimental toggle is ON. Empty when the toggle is OFF or no candidate data exists.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    @State private var hrvOverCountByDay: [String: Double] = [:]   // #1118

    var body: some View {
        let readings = BodyVitalSigns.readings(
            sourceRows: repo.vitalMetricRows,
            temperatureUnit: temperatureUnit,
            spo2CandidateByDay: spo2CandidateByDay,
            hrvOverCountByDay: hrvOverCountByDay,
            skinTempPreferred: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute,   // #1846
            epochs: BaselineStandard.referenceEpochs()   // fix J: Recalibrate reaches the vital tiles
        )
        // Raw SpO₂ is the strap's uncalibrated ADC mean, not a blood-oxygen value: it stays off the glance
        // unless experimental features are on and it decoded a value.
        .filter { $0.key != "spo2raw" || (PuffinExperiment.isEnabled && $0.value != nil) }
        // HRV and resting HR lead (the two the Charge and Stress reads lean on), then the rest.
        .sorted { HealthTileGrid.order($0.key) < HealthTileGrid.order($1.key) }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Vitals", trailing: BodyVitalSigns.latestDayLabel(readings))
            LazyVGrid(columns: HealthTileGrid.columns, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(readings) { reading in
                    vitalTile(reading)
                }
            }
        }
        .task(id: PuffinExperiment.spo2CandidateDisplayEnabled) {
            // #1118: load the per-night HRV over-count flags (always — no toggle) so the HRV tile can
            // caption an over-counted 4.0 night's reading "unverified". The engine writes "hrv_rr_overcount"
            // (1/0) under the "-noop" computed device ID; `exploreSeries` with source "my-whoop" reads it
            // from the computed metricSeries. Absent/0 on a clean or imported night → no caveat.
            let ocPts = await repo.exploreSeries(key: "hrv_rr_overcount", source: "my-whoop", days: 14)
            hrvOverCountByDay = Dictionary(ocPts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
            // #103/queue-11a: load the SpO₂ candidate nightly means from metricSeries when the toggle is
            // ON. The engine writes "spo2_candidate" under the "-noop" computed device ID; `exploreSeries`
            // with source "my-whoop" reads it from Layer 2 (computed metricSeries) — "my-whoop" is the
            // generic active-strap sentinel, resolved through `computedReadIds`, so this already covers
            // an Oura ring's own computed id. Empty when the toggle is OFF (the engine writes nothing) or
            // the owner has no in-band reading for its device.
            guard PuffinExperiment.spo2CandidateDisplayEnabled else {
                spo2CandidateByDay = [:]
                return
            }
            let pts = await repo.exploreSeries(key: "spo2_candidate", source: "my-whoop", days: 14)
            spo2CandidateByDay = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
    }

    @ViewBuilder
    private func vitalTile(_ reading: BodyVitalReading) -> some View {
        let tile = MetricTile(icon: HealthTileGrid.icon(for: reading.key), iconColor: reading.metricColor,
                              label: LocalizedStringKey(reading.label),
                              value: reading.value.map(reading.format), unit: reading.unit,
                              state: HealthTileGrid.stateWord(reading),
                              stateTone: reading.banding.band == .outOfRange ? .warning : .neutral,
                              trend: reading.sparkline, reservesTrendSlot: true,
                              isLoading: !repo.loaded)
            .accessibilityLabel(reading.accessibilityText)
        if let key = HealthTileGrid.catalogKey(for: reading.key) {
            MetricDetailLink(key: key) { tile }
        } else {
            tile
        }
    }
}

/// The tile grid's shared layout, icons, state words and detail keys.
enum HealthTileGrid {
    /// Two columns on a phone, more on wider panes; every tile the same height.
    static let columns = [GridItem(.adaptive(minimum: 160), spacing: NoopMetrics.gap)]

    /// The `MetricCatalog` key of the detail page a vital opens (the readings use their own short keys).
    static func catalogKey(for readingKey: String) -> String? {
        switch readingKey {
        case "hrv": return "hrv"
        case "rhr": return "rhr"
        case "resp": return "resp_rate"
        case "spo2": return "spo2"
        case "skin": return "skin_temp"
        default: return nil
        }
    }

    /// Display order of the vitals: HRV, resting HR, respiratory rate, blood oxygen, skin temperature.
    static func order(_ readingKey: String) -> Int {
        ["hrv", "rhr", "resp", "spo2", "skin", "spo2raw"].firstIndex(of: readingKey) ?? 99
    }

    static func icon(for readingKey: String) -> String {
        switch readingKey {
        case "hrv": return "waveform.path.ecg"
        case "rhr": return "heart"
        case "resp": return "lungs"
        case "spo2", "spo2raw": return "drop"
        case "skin": return "thermometer.medium"
        default: return "heart.text.square"
        }
    }

    /// One short state for the tile, from the reading's banding: which yardstick judged it and whether it
    /// sits inside it. The longer caption (day, source, caveat) belongs to the detail page.
    static func stateWord(_ reading: BodyVitalReading) -> String {
        if reading.key == "spo2raw" {
            return reading.value == nil ? String(localized: "No data") : String(localized: "Uncalibrated")
        }
        if reading.value != nil, reading.caveat != nil { return String(localized: "Unverified") }
        switch (reading.banding.band, reading.banding.basis) {
        case (.noData, _):               return String(localized: "No data")
        case (.inRange, .personal):      return String(localized: "In your range")
        case (.outOfRange, .personal):   return String(localized: "Off baseline")
        case (.inRange, .population):    return String(localized: "Typical range")
        case (.outOfRange, .population): return String(localized: "Outside range")
        }
    }
}

// MARK: - Fitness (Fitness Age · VO₂max · Vitality · Body Age)

/// The weekly fitness estimates as four tiles, plus the two pages that explain them: the Fitness Age
/// readiness checklist ("How accurate is this?") and what shaped your Vitality.
///
/// Fitness Age is a weekly, on-device fitness comparison (NOT a biological age) computed by
/// IntelligenceEngine from the Nes/HUNT model and read back from the "fitness_age" metricSeries; Vitality
/// and Body Age are the weekly wellness estimate from the mortality-hazard model. Depends only on `repo`,
/// `profile` and `intelligence`, so the ~1 Hz live HR stream never re-renders it.
private struct FitnessSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var router: NavRouter
    /// Drives the readiness page's "refresh Fitness Age" button (force an immediate recompute).
    @EnvironmentObject var intelligence: IntelligenceEngine

    /// Latest weekly Fitness Age (years) read from the "fitness_age" metricSeries, nil until loaded/computed.
    @State private var fitnessAge: Double?
    /// Latest estimated VO₂max (ml/kg/min) from "vo2max_est" — present even without a waist (the Uth
    /// HR-ratio fallback, #1391); a waist upgrades it to the more accurate Nes waist-based estimate.
    @State private var vo2max: Double?
    /// Estimator captured beside the latest value. nil is an honest legacy-unknown state, never inferred
    /// from today's waist because the profile may have changed since the point was scored.
    @State private var vo2maxEstimator: Vo2MaxEstimator?
    @State private var loaded = false
    /// True while a manual "refresh Fitness Age" recompute is running (spinner on the readiness page).
    @State private var refreshing = false

    @State private var vitality: Double?
    @State private var bodyAge: Double?
    @State private var vitalityLoaded = false

    #if os(macOS)
    /// The Mac has no Settings sheet on the router, so "Fix in Settings" opens Settings here.
    @State private var showSettings = false
    #endif

    /// Build the readiness verdict from the same signals IntelligenceEngine feeds the engine: the last 7
    /// computed/imported days give the resting-HR + activity coverage counts; the profile gives the rest.
    private var readiness: FitnessAgeReadiness {
        let last7 = repo.days.suffix(7)
        let rhrDays = last7.compactMap { $0.restingHr }.count
        let activityDays = last7.compactMap { $0.strain }.count
        return FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0,
            hasSex: !profile.sex.isEmpty,
            rhrDays: rhrDays,
            activityDays: activityDays,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0,
            hasWaist: profile.waistCm > 0)
    }

    /// The not-ready lead — delegates to the file-scope `fitnessReadyLeadCopy(rhrDays:hasAge:hasSex:)`,
    /// shared with the Today card's `MetricDetailView` tap-through so both surfaces show the SAME countdown.
    private func fitnessReadyLead() -> String {
        fitnessReadyLeadCopy(
            rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty)
    }

    private var contributions: [VitalityEngine.Contribution] {
        let last7 = repo.days.suffix(7)
        let nights = last7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let hrvs = last7.compactMap { $0.avgHrv }
        let rhrs = last7.compactMap { $0.restingHr }.map(Double.init)
        let steps = last7.compactMap { $0.steps }.map(Double.init)
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        // Aggregate EXACTLY as the stored headline does (IntelligenceEngine), so this "what's driving it"
        // breakdown reconciles with the Vitality / Body Age number it explains rather than being recomputed
        // on different statistics: resting HR + HRV are MEDIANED (robust to one outlier night), sleep +
        // steps are MEANED. Using the mean for all four let a single bad RHR/HRV reading drift the breakdown
        // out of step with the median-based headline (code review).
        return VitalityEngine.contributions(.init(
            chronoAge: Double(profile.age),
            restingHR: rhrs.isEmpty ? nil : IntelligenceEngine.medianOf(rhrs),
            sleepHours: mean(nights),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: nights),
            rmssd: hrvs.isEmpty ? nil : IntelligenceEngine.medianOf(hrvs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: mean(steps)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Fitness")
            LazyVGrid(columns: HealthTileGrid.columns, alignment: .leading, spacing: NoopMetrics.gap) {
                fitnessAgeTile
                MetricDetailLink(key: "vo2max_est") {
                    MetricTile(icon: "lungs", iconColor: StrandPalette.metricCyan, label: "VO₂max",
                               value: vo2max.map { String(format: "%.0f", $0) }, unit: "ml/kg/min",
                               isEstimate: vo2max != nil, isLoading: !loaded)
                }
                MetricDetailLink(key: "vitality") {
                    MetricTile(icon: "sparkles", iconColor: StrandPalette.chargeColor, label: "Vitality",
                               value: vitality.map { "\(Int($0.rounded()))" }, unit: String(localized: "of 100"),
                               state: vitalityLoaded && vitality == nil ? String(localized: "Not enough data yet") : nil,
                               isLoading: !vitalityLoaded)
                }
                MetricDetailLink(key: "body_age") {
                    MetricTile(icon: "figure.stand", iconColor: StrandPalette.chargeColor, label: "Body Age",
                               value: bodyAge.map { "\(Int($0.rounded()))" }, unit: String(localized: "yrs"),
                               state: bodyAge.map { bodyAgeDeltaLine(age: $0) },
                               stateTone: bodyAge.map { ageTone($0) } ?? .neutral,
                               isLoading: !vitalityLoaded)
                }
            }
            NoopListSection {
                InsightsDetailLink {
                    FitnessReadinessPage(readiness: readiness,
                                         lead: fitnessAge == nil ? fitnessReadyLead() : nil,
                                         fitnessAge: fitnessAge, vo2max: vo2max,
                                         vo2maxEstimator: vo2maxEstimator,
                                         refreshing: refreshing,
                                         onFix: openSettings,
                                         onRefresh: refreshFitnessAge)
                } label: {
                    NoopListRow(icon: "info.circle", iconColor: StrandPalette.accent, title: "How accurate is this?")
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                InsightsDetailLink {
                    VitalityFactorsPage(vitality: vitality, bodyAge: bodyAge, chronoAge: profile.age,
                                        contributions: contributions)
                } label: {
                    NoopListRow(icon: "chart.bar.xaxis", iconColor: StrandPalette.accent, title: "What shaped your Vitality")
                }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .task(id: repo.refreshSeq) { await loadVitality() }
        .insightsDemoPage("fitnessage") {
            FitnessReadinessPage(readiness: readiness, lead: fitnessAge == nil ? fitnessReadyLead() : nil,
                                 fitnessAge: fitnessAge, vo2max: vo2max, vo2maxEstimator: vo2maxEstimator,
                                 refreshing: refreshing, onFix: openSettings, onRefresh: refreshFitnessAge)
        }
        .insightsDemoPage("vitality") {
            VitalityFactorsPage(vitality: vitality, bodyAge: bodyAge, chronoAge: profile.age,
                                contributions: contributions)
        }
        #if os(macOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .frame(width: 900, height: 820)
        }
        #endif
    }

    /// Fitness Age: the age (with its ≤/≥ bound), its distance from your age as one state; it opens the
    /// trend when there is a value and the readiness checklist while there is not.
    @ViewBuilder
    private var fitnessAgeTile: some View {
        let tile = MetricTile(icon: "figure.run", iconColor: StrandPalette.chargeColor, label: "Fitness Age",
                              value: fitnessAge.map { "\(fitnessAgeBoundSymbol($0))\(Int($0.rounded()))" },
                              unit: String(localized: "yrs"),
                              state: fitnessAge.map { fitnessAgeState($0) }
                                  ?? (loaded ? String(localized: "Not enough data yet") : nil),
                              stateTone: fitnessAge.map { ageTone($0) } ?? .neutral,
                              isLoading: !loaded)
        if fitnessAge != nil {
            MetricDetailLink(key: "fitness_age") { tile }
        } else {
            InsightsDetailLink {
                FitnessReadinessPage(readiness: readiness, lead: fitnessReadyLead(),
                                     fitnessAge: nil, vo2max: vo2max, vo2maxEstimator: vo2maxEstimator,
                                     refreshing: refreshing, onFix: openSettings, onRefresh: refreshFitnessAge)
            } label: { tile }
        }
    }

    /// The distance from your age, short enough for a tile. A bounded reading is stated as a floor
    /// ("≥ 4 yrs younger"): every model output past the end of the scale banks as the bound, so a plain
    /// distance would present a floor as a measurement (#2173).
    private func fitnessAgeState(_ age: Double) -> String {
        let bound = fitnessAgeBoundSymbol(age)
        let line = bodyAgeDeltaLine(age: age)
        return bound.isEmpty ? line : "≥ \(line)"
    }

    /// Younger reads positive, older a warning; within a year of your age it is neutral.
    private func ageTone(_ age: Double) -> StrandTone {
        let delta = Double(profile.age) - age
        if Int(abs(delta).rounded()) == 0 { return .neutral }
        return delta > 0 ? .positive : .warning
    }

    /// The age delta as whole-phrase variants per count and direction, so translators see complete
    /// phrases (never a stitched plural or direction fragment).
    private func bodyAgeDeltaLine(age: Double) -> String {
        let delta = Double(profile.age) - age
        let younger = delta >= 0
        let yrs = Int(abs(delta).rounded())
        if yrs == 0 { return String(localized: "about your age") }
        switch (younger, yrs == 1) {
        case (true, true):   return String(localized: "1 yr younger")
        case (true, false):  return String(localized: "\(yrs) yrs younger")
        case (false, true):  return String(localized: "1 yr older")
        case (false, false): return String(localized: "\(yrs) yrs older")
        }
    }

    private func openSettings() {
        #if os(macOS)
        showSettings = true
        #else
        router.openSettings()
        #endif
    }

    private func refreshFitnessAge() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            _ = await intelligence.recomputeFitnessAgeOnly()
            await load()
            refreshing = false
        }
    }

    /// Load the latest weekly Fitness Age (+ optional VO₂max) from the strap's metricSeries. Uses the
    /// same `exploreSeries(key:source:)` path every other metric on this screen reads, with source
    /// "my-whoop" (the Repository merges the computed "-noop" rows under any real import). Takes the
    /// freshest point — the weekly value is keyed to the week's Saturday and refines through the week.
    private func load() async {
        let faPts = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        let vo2Resolution = await repo.resolvedSeries(key: "vo2max_est", source: "my-whoop")
        fitnessAge = faPts.last?.value
        if let latest = vo2Resolution.points.last {
            vo2max = latest.value
            let tag = await repo.scoreProvenanceTag(
                resolvedSource: latest.source, day: latest.day, metricKey: "vo2max_est")
            vo2maxEstimator = tag.flatMap { Vo2MaxEstimator(rawValue: $0) }
        } else {
            vo2max = nil
            vo2maxEstimator = nil
        }
        loaded = true
    }

    private func loadVitality() async {
        vitality = (await repo.exploreSeries(key: "vitality", source: "my-whoop")).last?.value
        bodyAge = (await repo.exploreSeries(key: "body_age", source: "my-whoop")).last?.value
        vitalityLoaded = true
    }
}

/// The Fitness Age not-ready lead: a concrete countdown of nights-of-wear still needed (from the shared
/// `nightsUntilReady`), noting the profile basics only when they're actually missing. File-scope (not a
/// view method) so BOTH Health's readiness page and the Today card's `MetricDetailView` tap-through
/// render the SAME copy from one source. Kept WORD-FOR-WORD identical to the Android `fitnessReadyLead`
/// so the two platforms match.
func fitnessReadyLeadCopy(rhrDays: Int, hasAge: Bool, hasSex: Bool) -> String {
    let remaining = FitnessAgeEngine.nightsUntilReady(rhrDays: rhrDays)
    let needsBasics = !hasAge || !hasSex
    switch (remaining, needsBasics) {
    case (0, false): return String(localized: "A few more days and we can show your Fitness Age.")
    case (0, true):  return String(localized: "Add your age and sex below and we can show your Fitness Age.")
    case (1, false): return String(localized: "1 more night of wear and we can show your Fitness Age.")
    case (1, true):  return String(localized: "1 more night of wear, plus your age and sex below, and we can show your Fitness Age.")
    case (let n, false): return String(localized: "\(n) more nights of wear and we can show your Fitness Age.")
    case (let n, true):  return String(localized: "\(n) more nights of wear, plus your age and sex below, and we can show your Fitness Age.")
    }
}

// MARK: - Fitness Age readiness page

/// "How accurate is this?": what the Fitness Age is built from, what is still missing, and the method,
/// one tap below the tile. The checklist groups inputs by ROLE exactly as the engine reports them:
/// "Drives your Fitness Age" (age/sex/resting-HR/activity) vs "Sharpens your VO₂max" (height+weight) —
/// never implying the body measurements sharpen the age (the body term cancels in the model).
private struct FitnessReadinessPage: View {
    let readiness: FitnessAgeReadiness
    /// The countdown shown while there is no value yet; nil once a value exists.
    let lead: String?
    let fitnessAge: Double?
    let vo2max: Double?
    let vo2maxEstimator: Vo2MaxEstimator?
    let refreshing: Bool
    let onFix: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ScreenScaffold(title: "Fitness Age", titleDisplay: .navigationBar) {
            ReadinessChecklistCard(readiness: readiness, lead: lead, onFix: onFix,
                                   onRefresh: fitnessAge == nil ? onRefresh : nil, refreshing: refreshing)
            AboutDisclosure(paragraphs: aboutParagraphs)
        }
    }

    private var aboutParagraphs: [String] {
        var out: [String] = []
        // At a bound the age has stopped carrying information: every model output past the end of the
        // scale banks as the same number, so someone still improving sees nothing move (#2184). The VO₂max
        // is NOT clamped and is the same estimate this age derives from, so it keeps resolving.
        if let fitnessAge, !fitnessAgeBoundSymbol(fitnessAge).isEmpty, vo2max != nil {
            out.append(String(localized: "Fitness Age stops here. VO₂max keeps moving."))
        }
        out.append(String(localized: "± \(Int(FitnessAgeEngine.displayBandYears)) yr · a fitness comparison, not a biological age"))
        if vo2max != nil {
            out.append("VO₂max: \(String(localized: "On-device")) · \(vo2MaxEstimatorDisplayName(vo2maxEstimator))")
        }
        out.append(String(localized: "Built from published methods (Nes/HUNT) on \(Platform.deviceNounPhrase). It's a fitness comparison against an average peer your age, not a biological or medical age."))
        return out
    }
}

/// The readiness checklist card: an optional lead line, then the engine's `items` as ✓/⚠/○ rows with
/// their `detail` text, GROUPED by `.role` into "Drives your Fitness Age" and "Sharpens your VO₂max".
/// A required-but-missing input shows a "Fix in Settings" affordance (the engine's required+missing
/// rows are age/sex; resting-HR can only be earned by wearing the strap, so it gets no fix button).
private struct ReadinessChecklistCard: View {
    let readiness: FitnessAgeReadiness
    /// Optional intro line shown above the groups (e.g. the "a few more days" no-value message).
    /// Already-localized text (from `fitnessReadyLead()`, which returns `String(localized:)`), so it's a
    /// plain `String` rendered verbatim — not a `LocalizedStringKey` (which would re-key a resolved string).
    let lead: String?
    /// Invoked when the user taps a required-missing row's "Fix in Settings".
    let onFix: () -> Void
    /// Optional force-recompute action (the "refresh Fitness Age" button, not-ready state only);
    /// `refreshing` swaps it for a spinner while the recompute runs. nil = no button.
    var onRefresh: (() -> Void)? = nil
    var refreshing: Bool = false

    private var drivesAge: [FitnessReadinessItem] { readiness.items.filter { $0.role == .drivesAge } }
    /// The engine still reports an optional waist row, but Settings no longer has a waist field, so the
    /// checklist leaves it out rather than listing an input the user has no way to provide.
    private var unlocksVO2: [FitnessReadinessItem] {
        readiness.items.filter { $0.role == .unlocksVO2max && $0.key != "waist" }
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space2) {
                    confidencePill
                    Spacer(minLength: 0)
                    // Force-recompute affordance: Nara scores Fitness Age weekly, so this applies it NOW
                    // from stored data. Spinner while it runs.
                    if let onRefresh {
                        if refreshing {
                            ProgressView().controlSize(.small).tint(StrandPalette.accent)
                                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                        } else {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
                                    .font(StrandFont.icon(.inline))
                                    .foregroundStyle(StrandPalette.accent)
                                    .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Refresh Fitness Age now")
                        }
                    }
                }
                if let lead {
                    Text(lead)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                group(title: "Drives your Fitness Age", items: drivesAge)
                group(title: "Sharpens your VO₂max", items: unlocksVO2)
            }
        }
    }

    /// The overall confidence, as the one state pill.
    @ViewBuilder private var confidencePill: some View {
        switch readiness.confidence {
        case .ready:    StatePill("Ready", tone: .positive)
        case .estimate: StatePill("Estimate (partial data)", tone: .warning)
        case .notReady: StatePill("Not enough data yet", tone: .neutral)
        }
    }

    @ViewBuilder
    private func group(title: LocalizedStringKey, items: [FitnessReadinessItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(title).strandLabel()
                ForEach(items, id: \.key) { item in
                    readinessRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func readinessRow(_ item: FitnessReadinessItem) -> some View {
        // A required/optional input that's still unsatisfied earns a "Fix in Settings" affordance, but
        // only when it's actually fixable there (age/sex/body metrics) — resting-HR and activity
        // coverage come from wearing the strap, so those get no fix button.
        let fixable = item.status != .satisfied
            && (item.key == "age" || item.key == "sex" || item.key == "bodyMetrics")
        let row = HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Image(systemName: statusIcon(item.status))
                .font(StrandFont.icon(.inline))
                .foregroundStyle(statusColor(item.status))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(item.label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(item.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            if fixable {
                Button(action: onFix) {
                    Text("Fix in Settings")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.label): \(item.detail). Fix in Settings.")
            }
        }
        // When a Fix button is present keep it as its own VoiceOver stop (.contain); otherwise fold the
        // whole row into one labelled stop. Two branches so we never pass a nil accessibility label.
        if fixable {
            row.accessibilityElement(children: .contain)
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label), \(statusWord(item.status)). \(item.detail)")
        }
    }

    private func statusIcon(_ s: FitnessReadinessStatus) -> String {
        switch s {
        case .satisfied: return "checkmark.circle.fill"
        case .partial:   return "exclamationmark.triangle.fill"
        case .missing:   return "circle"
        }
    }
    private func statusColor(_ s: FitnessReadinessStatus) -> Color {
        switch s {
        case .satisfied: return StrandPalette.statusPositive
        case .partial:   return StrandPalette.statusWarning
        case .missing:   return StrandPalette.textTertiary
        }
    }
    private func statusWord(_ s: FitnessReadinessStatus) -> String {
        switch s {
        case .satisfied: return String(localized: "ready")
        case .partial:   return String(localized: "partial")
        case .missing:   return String(localized: "missing")
        }
    }
}

// MARK: - What shaped your Vitality

/// The factors behind the weekly Vitality and Body Age, one tap below the tiles: each factor's pull as a
/// bar left (holding you back) or right (helping) of neutral, recomputed the same way the engine does.
private struct VitalityFactorsPage: View {
    let vitality: Double?
    let bodyAge: Double?
    let chronoAge: Int
    let contributions: [VitalityEngine.Contribution]

    /// Most helpful first. A negative log-hazard lowers risk, so it is drawn as a positive pull.
    private var sorted: [VitalityEngine.Contribution] { contributions.sorted { $0.lnHazard < $1.lnHazard } }
    private var magnitude: Double { max(0.05, contributions.map { abs($0.lnHazard) }.max() ?? 0) }

    var body: some View {
        ScreenScaffold(title: "Vitality", titleDisplay: .navigationBar) {
            HStack(spacing: NoopMetrics.space4) {
                ScoreRing(fraction: vitality.map { $0 / 100 }, value: vitality.map { "\(Int($0.rounded()))" } ?? "—",
                          caption: String(localized: "of 100"), color: StrandPalette.chargeColor, diameter: 96)
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Body Age").strandLabel()
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                        Text(bodyAge.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(StrandFont.number(28))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if bodyAge != nil {
                            Text("yrs").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("What shaped it")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        if sorted.isEmpty {
                            Text("A few more days and we can show your Vitality.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        ForEach(sorted, id: \.key) { factor in
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                HStack {
                                    Text(factor.label)
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text(factorWord(factor))
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(factor.lnHazard < 0 ? StrandPalette.statusPositive
                                                         : (factor.lnHazard > 0 ? StrandPalette.statusWarning
                                                            : StrandPalette.textTertiary))
                                }
                                InsightsDivergingBar(value: -factor.lnHazard, magnitude: magnitude)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            AboutDisclosure(paragraphs: [
                String(localized: "A wellness estimate from your habits, not a clinical biological age."),
            ])
        }
    }

    private func factorWord(_ factor: VitalityEngine.Contribution) -> String {
        if factor.lnHazard < 0 { return String(localized: "Helping") }
        if factor.lnHazard > 0 { return String(localized: "Holding you back") }
        return String(localized: "Neutral")
    }
}

// MARK: - Body clock and cycle

/// The skin-temperature reads that are not vitals: the body-clock estimate and (opt-in) cycle awareness,
/// as rows that open their cards. Driven by pure StrandAnalytics engine results the analytics pass
/// computed and `AppModel` publishes. Hidden when neither applies.
private struct RhythmsSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    /// The cycle-awareness opt-in (default OFF). The same key AppModel reads, so a flip is consistent.
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    /// #hide-cycle: the user's "not for me" opt-out. When set, the cycle opt-in invitation is suppressed
    /// here; reversible from Automations.
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false

    /// Whether the cycle-awareness opt-in is offered for this profile (#801). Delegates to the shared
    /// ``ProfileStore/cycleAwarenessApplies`` gate so Health + Automations stay in lockstep: cycle phase
    /// is read from the menstrual skin-temperature shift, so the opt-in is NOT shown for male profiles.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies && !cycleHidden }

    private var showsCycle: Bool {
        // If a profile that previously enabled it later switches to male, the existing awareness card is
        // still honoured rather than silently hiding their data; only the OPT-IN invitation is gated.
        (cycleEnabled && model.cyclePhase != nil) || (!cycleEnabled && cycleOptInApplies)
    }

    var body: some View {
        if model.circadianPhase != nil || showsCycle {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Rhythms")
                NoopListSection {
                    if let phase = model.circadianPhase {
                        InsightsDetailLink {
                            ScreenScaffold(title: "Heart-rate rhythm", titleDisplay: .navigationBar) {
                                BodyClockCard(estimate: phase)
                            }
                        } label: {
                            NoopListRow(icon: "clock", iconColor: StrandPalette.metricAmber, title: "Heart-rate rhythm")
                        }
                    }
                    if model.circadianPhase != nil && showsCycle {
                        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    }
                    if showsCycle {
                        InsightsDetailLink {
                            HealthCyclePage()
                        } label: {
                            NoopListRow(icon: "circle.dotted.circle", iconColor: StrandPalette.metricRose,
                                        title: "Cycle awareness",
                                        value: cycleEnabled ? nil : String(localized: "Off"))
                        }
                    }
                }
            }
        }
    }
}

/// Cycle awareness one tap below its row: the awareness card when it is on, else the opt-in.
private struct HealthCyclePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @State private var cycleTrackerPresented = false

    var body: some View {
        ScreenScaffold(title: "Cycle awareness", titleDisplay: .navigationBar) {
            if cycleEnabled, let cycle = model.cyclePhase {
                CycleAwarenessCard(result: cycle, curve: model.cycleCurve,
                                   onLogPeriod: {
                                       Task {
                                           await repo.logPeriodStart(day: Repository.localDayKey(Date()))
                                           await model.refreshV5Signals()
                                       }
                                   },
                                   onOpenDetail: { cycleTrackerPresented = true },
                                   // Symmetric off (#801): turn it off in-place, here in Health, where
                                   // it was turned on, not only from Automations.
                                   onTurnOff: {
                                       cycleEnabled = false
                                       model.cycleAwarenessEnabled = false
                                       Task { await model.refreshV5Signals() }
                                   })
            } else if !cycleEnabled {
                CycleAwarenessOptInCard(onEnable: {
                    cycleEnabled = true
                    model.cycleAwarenessEnabled = true
                    Task { await model.refreshV5Signals() }
                })
            } else {
                ComingSoon(what: "Wear the strap overnight and these read from your nightly skin temperature.")
            }
        }
        .sheet(isPresented: $cycleTrackerPresented) {
            if let cycle = model.cyclePhase {
                CycleTrackerView(result: cycle, curve: model.cycleCurve)
                    .environmentObject(repo)
                    .environmentObject(model)
            }
        }
    }
}

// MARK: - Records (Lab Book · Your Data, Fused)

/// The records logbook (Lab Book) and the multi-device fused record, as two rows. On iOS they push in
/// this stack (never a sheet over whatever presented Health); the Mac selects their sidebar items.
private struct HealthRecordsSection: View {
    @EnvironmentObject var router: NavRouter

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Records")
            NoopListSection {
                recordRow(title: "Lab Book", icon: "books.vertical", open: { router.openLabBook() }) {
                    LabBookView()
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                recordRow(title: "Your Data, Fused", icon: "square.stack.3d.up", open: { router.openFusedRecord() }) {
                    FusedRecordHost()
                }
            }
        }
    }

    @ViewBuilder
    private func recordRow<Destination: View>(title: LocalizedStringKey, icon: String, open: @escaping () -> Void,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        #if os(macOS)
        Button(action: open) {
            NoopListRow(icon: icon, iconColor: StrandPalette.accent, title: title)
        }
        .buttonStyle(.plain)
        #else
        NavigationLink { destination() } label: {
            NoopListRow(icon: icon, iconColor: StrandPalette.accent, title: title)
        }
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Health") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 462, efficiency: 92,
            deepMin: 96, remMin: 108, lightMin: 240, disturbances: 7,
            restingHr: 52, avgHrv: 74, recovery: 81, strain: 11.4,
            exerciseCount: 1,
            spo2Pct: 97, skinTempDevC: 34.2, respRateBpm: 14.6
        )
    ]
    repo.loaded = true

    return NavigationStack {
        HealthView()
    }
    .environmentObject(repo)
    .environmentObject(LiveState())
    .environmentObject(ProfileStore())
    .environmentObject(AppModel())
    .environmentObject(NavRouter())
    .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
    .frame(width: 900, height: 760)
}

/// Deterministic render target for `--demo-screen fitnessage` (pair with `--demo-seed`): the Fitness
/// tiles on the production scaffold.
struct FitnessAgeDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Fitness Age", titleDisplay: .navigationBar) {
            FitnessSection()
        }
    }
}

/// Deterministic render target for `--demo-screen vitality` (pair with `--demo-seed`).
struct VitalityDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Vitality", titleDisplay: .navigationBar) {
            FitnessSection()
        }
    }
}
#endif

/// The symbol a stored Fitness Age needs when it is sitting on a reporting bound (#2173).
///
/// `FitnessAgeEngine` clamps to [minAge, maxAge], so every model output below 20 is stored as
/// exactly 20.0 and every output above 80 as exactly 80.0. A reader cannot tell either from a
/// genuine 20 or 80, and the number looks as exact as every other number on the screen, which is
/// what makes a floored reading read like a sync or scoring fault rather than the end of the scale.
///
/// Decided from the value rather than carried out of the engine, matching the Kotlin twin. The
/// clamp returns the bound constant itself, so equality is exact and needs no tolerance, and
/// deciding here covers the weekly rows already banked, which no flag added today could reach.
/// A reading that is genuinely 20.0 is therefore also called "20 or younger", which is true of it.
/// Saying "<20" would need the unclamped value, and that is gone before anything is stored.
func fitnessAgeBoundSymbol(_ value: Double) -> String {
    if value <= FitnessAgeEngine.minAge { return "≤" }
    if value >= FitnessAgeEngine.maxAge { return "≥" }
    return ""
}
