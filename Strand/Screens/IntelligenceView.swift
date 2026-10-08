import SwiftUI
import StrandDesign
import StrandAnalytics

/// Intelligence — Nara's own recovery/strain/sleep scores, computed on-device from raw strap data
/// using the WHOOP model shape. Makes the app independent of WHOOP's cloud for live-collected days.
///
/// i18n: the By-Day core labels (Effort/Charge/Rest/HRV/RHR) and the Charge-model "Effort" heading are
/// looked up via `String(localized:)` so non-English locales (e.g. German, issue #1020) actually
/// translate them instead of rendering the English literal. pt-PT catalog strings adopted from
/// tigercraft4's PR #1018 (marked needs_review — machine ES→PT conversion pending native review).
struct IntelligenceView: View {
    @EnvironmentObject var intelligence: IntelligenceEngine
    // NOTE: IntelligenceView deliberately does NOT observe `LiveState`. A connected strap publishes at
    // ~1 Hz, which would re-evaluate this body (and its lazy By-Day list) on every tick. The only live
    // dependency — the "Syncing strap history…" note shown over the empty state — owns its OWN
    // `@EnvironmentObject var live` in the `IntelSyncingNote` leaf below (mirrors the Today/Sleep
    // leaf-scoping pattern), so a tick refreshes only that note.

    @State private var range: ChartRange = .month

    // Effort display scale (#268) — routes every Effort value/label on this screen. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        // `lazy` so the trailing By-Day `ForEach` renders day cards on demand. With an 800+ day
        // imported history, an eager VStack built every card up-front on the main thread and froze
        // the app when ALL was tapped (#345); LazyVStack only materialises what's on screen.
        ScreenScaffold(title: "Intelligence", titleDisplay: .navigationBar, lazy: true) {
            if let f = forecast { forecastCard(f) }
            if intelligence.computing {
                NoopCard {
                    HStack(spacing: NoopMetrics.rowSpacing) {
                        ProgressView().controlSize(.small)
                        Text("Crunching your raw streams…").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            } else if let note = intelligence.note {
                NoopCard {
                    HStack(alignment: .top, spacing: NoopMetrics.rowSpacing) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(StrandPalette.chargeColor)
                            .accessibilityHidden(true)
                        Text(note).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if intelligence.results.isEmpty {
                // While the strap is mid-offload, say so — "no days" reads as final otherwise (#77). The
                // note owns the `LiveState` observation in its own leaf so the chunk count ticks without
                // re-rendering Intelligence (identical output to the prior inline check).
                IntelSyncingNote()
                DataPendingNote(
                    title: "Building from your strap",
                    message: "This builds from the strap as it syncs. Effort and rest appear after you have worn it and slept a night. Charge needs about four nights of sleep to learn your baseline (you'll see \"Calibrating\" until then), and keeps sharpening over your first couple of weeks. On a WHOOP 5 or MG the strap banks little history, so the night count can climb slowly or sit at 0 of 4 until you have worn it across a few nights. That's its sync limit, not a fault. Import your WHOOP export to skip the wait.",
                    symbol: "brain.head.profile"
                )
            } else {
                // The section title with the day count, then the one range control. Narrows the per-day
                // list to a recent window (lexicographic yyyy-MM-dd compare == chronological).
                // Whole-phrase variants per count so translators never see a stitched plural.
                SectionHeader("By day", trailing: filtered.count == 1 ? String(localized: "1 day")
                                                                       : String(localized: "\(filtered.count) days"))
                RangeControl(selection: $range)
                if filtered.isEmpty {
                    NoopCard {
                        Text("No scored days in this window. Widen the range or import more history.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(filtered) { day in
                        dayCard(day)
                    }
                }
            }
            explainerCard
        }
        .task { if intelligence.results.isEmpty { await intelligence.analyzeRecent() } }
        .toolbar {
            ToolbarItem {
                Button { Task { await intelligence.analyzeRecent() } } label: {
                    Label("Recompute", systemImage: "arrow.clockwise")
                }
                .disabled(intelligence.computing)
            }
        }
    }

    /// The day list narrowed to the selected window. `nil` cutoff (All) shows everything.
    private var filtered: [IntelligenceEngine.Computed] {
        guard let n = range.days else { return intelligence.results }
        let date = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        let cutoff = Self.dayFmt.string(from: date)
        return intelligence.results.filter { $0.day >= cutoff }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Evening forecast of tomorrow-morning Charge from tonight's known levers. Anchored to
    /// the recent Charge baseline, nudged by today's Effort vs your norm and how much sleep
    /// you typically bank, then mean-reverted. `results` is newest-first; the forecaster wants
    /// oldest→newest, so each series is reversed. `nil` (and the card hidden) until there are
    /// enough scored nights to anchor honestly — never a fabricated number.
    private var forecast: RecoveryForecast? {
        let charge = intelligence.results.compactMap { $0.recovery }.reversed()
        let effort = intelligence.results.compactMap { $0.strain }.reversed()
        // Planned sleep tonight = the recent typical night (the honest "if you sleep ~Xh"
        // assumption surfaced in the card), from the scored nights that have a sleep total.
        let sleeps = intelligence.results.compactMap { $0.sleepMin }
        let plannedHours = sleeps.isEmpty ? RecoveryForecaster.defaultNeedHours
            : (sleeps.reduce(0, +) / Double(sleeps.count)) / 60.0
        return RecoveryForecaster.forecast(recentCharge: Array(charge),
                                           recentEffort: Array(effort),
                                           todayEffort: intelligence.results.first?.strain,
                                           plannedSleepHours: plannedHours)
    }

    /// The forecast: tomorrow-morning Charge in the one score ring (its band colour), with the ± band and
    /// the plain-English read beside it. An estimate, said as one.
    private func forecastCard(_ f: RecoveryForecast) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Tomorrow's Charge", trailing: String(localized: "Estimate"))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack(spacing: NoopMetrics.space5) {
                        ScoreRing(fraction: f.charge / 100, value: "\(Int(f.charge.rounded()))",
                                  caption: "± \(Int(f.band.rounded()))",
                                  color: InsightsScoreBands.charge.band(for: f.charge).color, diameter: 112)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Tomorrow's Charge estimate \(Int(f.charge.rounded())) plus or minus \(Int(f.band.rounded()))")
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text(StrandPalette.recoveryState(f.charge))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("You'll likely wake around \(Int(f.charge.rounded())) ± \(Int(f.band.rounded())) Charge if you sleep about \(sleepHoursLabel(f.plannedSleepHours)) tonight.")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Estimate from today's effort, your typical sleep and your \(f.nights)-night recovery baseline, not a measurement. Your real Charge is scored from tomorrow's HRV when you wake.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "~7h" / "~7h 30m" for the planned-sleep assumption (hours rounded to the nearest 30 min).
    private func sleepHoursLabel(_ hours: Double) -> String {
        let half = (hours * 2).rounded() / 2
        let h = Int(half)
        let m = Int((half - Double(h)) * 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// How the scores are built, collapsed at the foot of the page: the Charge model's five weighted
    /// inputs as proportional bars, and the Effort scale.
    private var explainerCard: some View {
        AboutDisclosure("How this works") {
            AboutParagraphs([
                String(localized: "Charge weighs your HRV against your personal baseline (~55%), resting heart rate (~20%), rest quality (~15%), respiration (~5%) and skin-temperature deviation (~5%). Effort is a 0-\(UnitFormatter.effortScaleMax(effortScale)) cardiovascular load from time in heart-rate zones. Rest is staged from movement and heart rate. Everything is computed here from the strap's raw data. It works for any day Nara collected raw streams."),
            ])
            InsightsComparisonBars(bars: [
                .init(id: "hrv", label: String(localized: "Heart-rate variability"), value: 0.55, valueText: "~55%", detail: "", color: StrandPalette.metricPurple),
                .init(id: "rhr", label: String(localized: "Resting heart rate"), value: 0.20, valueText: "~20%", detail: "", color: StrandPalette.metricRose),
                .init(id: "rest", label: String(localized: "Rest quality"), value: 0.15, valueText: "~15%", detail: "", color: StrandPalette.restColor),
                .init(id: "resp", label: String(localized: "Respiration"), value: 0.05, valueText: "~5%", detail: "", color: StrandPalette.metricCyan),
                .init(id: "skin", label: String(localized: "Skin-temperature deviation"), value: 0.05, valueText: "~5%", detail: "", color: StrandPalette.metricAmber),
            ], domain: 0...0.55)
        }
    }

    private func dayCard(_ d: IntelligenceEngine.Computed) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text(d.day).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    // A3: the existing per-day Charge confidence as a small dot + tier tag pill
                    // (CALIBRATING / EST. / REL.) next to the source badge. Pure presentation of
                    // `d.confidence` , only shown once there's a Charge to qualify.
                    if d.recovery != nil {
                        ConfidenceTierChip(confidence: d.confidence)
                    }
                    // The REAL source of the day's dashboard headline, not a hard-coded "NOOP-computed".
                    // The By-Day numbers are always NOOP's on-device scores, but when an import covers the
                    // day it WINS the dashboard merge, so the badge says so ("Whoop" / "Apple Health") and
                    // a strap-scored night reads "On-device". Dynamic String → wrap in "\()" so it's shown
                    // verbatim, not looked up as a LocalizedStringKey (the String≠LocalizedStringKey
                    // SwiftUI footgun). Imported rows use the accent tint to stand out from computed ones.
                    SourceBadge("\(d.source.badge)",
                                tint: d.source == .computed ? StrandPalette.chargeColor : StrandPalette.accent)
                }
                HStack(spacing: 0) {
                    stat(String(localized: "Charge"), d.recovery.map { "\(Int($0.rounded())) %" } ?? "—")
                    stat(String(localized: "Effort"), d.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—")
                    stat(String(localized: "Rest"), d.sleepMin.map { "\(Int($0 / 60))h \(Int($0.truncatingRemainder(dividingBy: 60)))m" } ?? "—")
                    stat(String(localized: "HRV"), d.hrv.map { "\(Int($0.rounded()))" } ?? "—")
                    stat(String(localized: "RHR"), d.rhr.map { "\($0)" } ?? "—")
                }
                // A1: "What shaped it" , one row per engine-supplied Charge driver. Gated on a non-empty
                // list so a cold-start / calibrating night (no real contributions to attribute) shows
                // nothing here rather than a fake breakdown. A5's relative skin-temp marker rides at the
                // foot when the night carries one.
                if !d.drivers.isEmpty {
                    ChargeBreakdownSection(drivers: d.drivers,
                                           confidence: d.confidence,
                                           skinTempRel: d.skinTempRel)
                        .padding(.top, NoopMetrics.space1)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // `lineLimit` + `minimumScaleFactor` so a long label shrinks instead of running into its
            // neighbour. The five stats share the width as equal columns with NO gap between them
            // (`HStack(spacing: 0)` above), so a label wide enough to fill its column touches the next
            // one: "CHARGE" and "EFFORT" are the two longest and collide first, while REST / HRV / RHR
            // still look spaced. Reported from a device screenshot reading "CHARGEEFFORT".
            //
            // The VALUE below has carried this protection all along; only the label went without. The
            // Android twin's label already sets `maxLines = 1` with `TextOverflow.Ellipsis`, so this was
            // an iOS-only gap rather than a shared one.
            //
            // Scaled rather than truncated, matching how the value directly beneath is treated: "CHARG…"
            // reads worse than a slightly smaller "CHARGE". Larger Dynamic Type is where this bites, so
            // the floor has to leave room for the longest label at the widest text size.
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value).font(StrandFont.number(20)).foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation in its own leaf (scroll-stutter isolation) so the chunk count ticks without
/// re-rendering IntelligenceView. Renders byte-for-byte what the prior inline `live.backfilling` check did.
private struct IntelSyncingNote: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}
