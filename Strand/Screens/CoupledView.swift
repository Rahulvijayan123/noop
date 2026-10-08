import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Coupled view (task #43), the optional classic coupled day read
//
// An optional, default-OFF day view that reads like the classic coupled home: one screen, three numbers,
// Recovery % / Day Strain on 0–21 / Sleep, for users who came across from another band and want the old
// glance back. Nara's Today stays the default and is untouched.
//
// DISPLAY-ONLY, like the #268 Effort-scale toggle. This screen invents no score and stores nothing: it
// reads the SAME values Today already computes (recovery / Rest composite / Effort strain / readiness) and
// re-presents them in the coupled layout. The only new mapping is the OPTIMAL strain band, a pure
// display-only read of today's recovery to a suggested strain range (never fed back into scoring).
//
// It renders in the shared design language — the three scores are the one score ring (recovery in its
// band colour, strain on the 0–21 axis, sleep performance), the optimal-strain band is a shaded track with
// today's strain marked, on the flat card and canvas — all routed through StrandPalette. The word "WHOOP" appears
// in NO shipped UI string here (legal posture); the screen is called "Coupled view".
//
// Tap-throughs, matching the sibling screens' deep-link/back behaviour: the hero ring opens the Charge
// breakdown ("What shaped it", the same shared ChargeBreakdownSection content the Today ring opens, hosted
// here because TodayView's own sheet is view-private); the sleep row pushes the Sleep screen.

struct CoupledView: View {
    @EnvironmentObject var repo: Repository

    // Effort is stored 0–100; the coupled read is always the 0–21 Day-Strain axis regardless of the user's
    // #268 display toggle, so the gauge reads like the classic coupled home. Display-only conversion.
    private let strainScale: EffortScale = .whoop

    /// The Charge breakdown sheet, the hero ring's tap target. Its body builds LAZILY on presentation
    /// (the #819 pattern), reading drivers derived from the same displayed row the ring shows.
    @State private var showChargeBreakdown = false

    /// The learned habitual midsleep (local time-of-day seconds), loaded once so the bed→wake span
    /// resolves the SAME main-night pick the Sleep tab hero and the daily total use (#294). nil under
    /// the cold-start threshold, which keeps the broad overnight-band bonus.
    @State private var habitualMidsleepSec: Int? = nil

    /// Today's all-source workout count materialized onto the same physiological cycle as the other cards.
    @State private var workoutsToday: Int = 0

    /// The day the coupled read describes, today's resolved row (the same `resolveToday` #304/#144 boundary
    /// Today anchors on), never a second store read.
    private var day: DailyMetric? { repo.today }

    /// Today's day key, tracking the resolved row when one exists (the Today idiom).
    private var todayKey: String { day?.day ?? Repository.logicalDayKey(Date()) }

    /// Recovery cold-start: nights banked so far while the HRV baseline still seeds, nil once recovery
    /// exists. The SAME pure helper Today's ring reads, so the two screens can't disagree.
    private var calibrationNights: Int? {
        RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                         dayKeys: repo.days.map(\.day),
                                         hasRecovery: day?.recovery != nil)
    }

    /// The last strictly-prior scored recovery day, so a just-rolled-over morning carries yesterday's read
    /// rather than blanking, exactly the anchor Today uses for readiness (#543).
    ///
    /// #1458: through the SAME selector Today uses, not a local re-derivation. This read
    /// `repo.days.last(where: { $0.recovery != nil && $0.day < todayKey })`, which has no `todayScored`
    /// guard — so on a day that HAS a score it still returned a prior day, and the hero's Charge sheet
    /// opened that older night while the card beside it showed today's number. It also skipped the
    /// calibrating gate, so a cold-start install could carry a value Today refuses. Reported on Android,
    /// but the defect was identical here: the twins agreed with each other and were both wrong.
    private var carriedRecoveryDay: DailyMetric? {
        TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: todayKey,
            isToday: true,   // the Coupled view has no day selector; it is always today
            todayScored: day?.recovery != nil,
            isCalibrating: calibrationNights != nil)
    }

    /// The recovery value the ring shows: today's if scored, else the carried prior day's (never fabricated).
    private var recovery: Double? { day?.recovery ?? carriedRecoveryDay?.recovery }

    /// True when the hero is showing the CARRIED prior score rather than today's own, which drives the
    /// dimmed ring + the "Last night · <date>" stamp so an old number is never passed off as new (#543/#779).
    private var isCarryingRecovery: Bool { day?.recovery == nil && carriedRecoveryDay?.recovery != nil }

    /// Effort strain on NOOP's 0–100 axis for the day (stored row; no live recompute here, this is a
    /// glance screen, not the primary Today hero). nil when the day has no scored Effort.
    private var strain100: Double? { day?.strain }

    /// Day strain mapped onto the 0–21 coupled axis via the SHIPPED formatter (UnitFormatter.effortValue),
    /// so the number matches every other Effort read-out's conversion factor exactly.
    private var dayStrain21: Double? { strain100.map { UnitFormatter.effortValue($0, scale: strainScale) } }

    /// Sleep performance % for the day, the SAME single source of truth the Today Rest score and the Sleep
    /// detail graph read: the imported figure when the export carried one, else the resolved Rest composite.
    /// Never a local hours-vs-need approximation (keeps the coupled read in agreement with Today's Rest).
    private var sleepPerformance: Double? {
        guard let d = day else { return nil }
        if let p = repo.importedSleep[d.day]?.performancePct { return p }
        return AnalyticsEngine.Rest.composite(daily: d)
    }

    /// On-device readiness, computed EXACTLY as Today does (ReadinessEngine.evaluate over the same rows,
    /// anchored on the last scored day ONLY when carrying), so the one-word pill matches the home screen's
    /// read. The carried anchor is gated on `isCarryingRecovery` (Today's `!todayScored` gate): on a normal
    /// scored day today's own key wins, so Coupled's pill can't diverge from Today's onto yesterday (#787).
    private var readinessLevel: ReadinessEngine.Level {
        let anchor = (isCarryingRecovery ? carriedRecoveryDay?.day : day?.day) ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor, context: .app()).level
    }

    var body: some View {
        // CoupledView is pushed from Today's card row. On iOS each tab supplies a NavigationStack, so the
        // sleep-row + breakdown pushes land in the ambient stack. On macOS this can render as a detail pane
        // with NO enclosing NavigationStack, so — exactly like MetricExplorerView / TrendsView (#753) —
        // wrap the scaffold in one here so the pushes get Back chrome instead of hanging. Same shared
        // scaffold renders on both.
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(title: "Day", dateLine: dateText, titleDisplay: .navigationBar,
                       isLoading: !repo.loaded) {
            ViewThatFits(in: .horizontal) {
                // Regular width (macOS / iPad): hero left, strain + sleep stacked right in a 2-column grid.
                HStack(alignment: .top, spacing: NoopMetrics.gap) {
                    heroCard
                        .frame(maxWidth: .infinity)
                    VStack(spacing: NoopMetrics.gap) {
                        strainCard
                        sleepCard
                    }
                    .frame(maxWidth: .infinity)
                }
                // Compact (iPhone): the three cards stack full-width.
                VStack(spacing: NoopMetrics.gap) {
                    heroCard
                    strainCard
                    sleepCard
                }
            }
            // The coupled read of Nara's OWN scores (same data, different lens) — the brand word of the
            // other band never appears in a shipped UI string here (legal posture).
            AboutDisclosure(paragraphs: [
                String(localized: "A classic one-glance read of Nara's own scores. Same data, different lens."),
            ])
        }
        .sheet(isPresented: $showChargeBreakdown) { chargeBreakdownSheet }
        // Loads the SAME learned habitual the Sleep tab hero threads into its main-night pick, so the
        // bed→wake span below resolves identically (#294). Re-runs on a sync/import refresh.
        .task(id: repo.refreshSeq) {
            habitualMidsleepSec = await repo.habitualMidsleepSec()
            workoutsToday = day?.exerciseCount ?? 0
        }
    }

    // MARK: Header date line, "Today, d MMM"

    private var dateText: String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return String(localized: "Today, \(f.string(from: Date()))")
    }

    // MARK: 1. HERO, the recovery ring, coupled read (tap = the Charge breakdown)

    /// The recovery read as the one score ring, in the colour of its band (`RecoveryScorer` thresholds),
    /// with the readiness word beneath. The whole hero is a button opening the Charge breakdown, mirroring
    /// Today's Charge-ring tap (A1).
    private var heroCard: some View {
        Button {
            showChargeBreakdown = true
        } label: {
            NoopCard {
                VStack(spacing: NoopMetrics.cardInnerSpacing) {
                    HStack {
                        Text("Recovery")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    ScoreRing(fraction: recovery.map { $0 / 100 },
                              value: recovery.map { "\(Int($0.rounded()))" } ?? "—",
                              caption: "%",
                              color: recovery.map { InsightsScoreBands.charge.band(for: $0).color }
                                  ?? StrandPalette.textTertiary,
                              diameter: 168)
                        // A carried (not-yet-rescored) morning reads dimmed, the Today #802 idiom.
                        .opacity(isCarryingRecovery ? 0.7 : 1)
                    if let word = TodayView.readinessWord(readinessLevel) {
                        StatePill(LocalizedStringKey(word), tone: readinessTone(readinessLevel))
                            .accessibilityLabel("Readiness: \(word)")
                    }
                    heroCaption
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
        .accessibilityHint("See what shaped your Charge")
    }

    /// The honest state line under the ring: the "Last night · <date>" stamp when carrying a prior score
    /// (#543/#779, via the SAME pure caption Today uses), or the calibrating progress while the baseline
    /// seeds. Nothing when today's own score is showing.
    @ViewBuilder
    private var heroCaption: some View {
        if isCarryingRecovery, let prior = carriedRecoveryDay {
            Text(TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else if recovery == nil, let banked = calibrationNights {
            Text(ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var heroAccessibilityLabel: String {
        if let r = recovery { return String(localized: "Recovery \(Int(r.rounded())) percent") }
        if let banked = calibrationNights {
            return String(localized: "Recovery calibrating, \(banked) of \(Baselines.minNightsSeed) nights")
        }
        return String(localized: "Recovery, no data yet")
    }

    /// The readiness level as the pill's tone, the same ordering TodayView.readinessColor uses.
    private func readinessTone(_ l: ReadinessEngine.Level) -> StrandTone {
        switch l {
        case .primed:       return .positive
        case .balanced:     return .positive
        case .strained:     return .warning
        case .rundown:      return .critical
        case .insufficient: return .neutral
        }
    }

    // MARK: 2. STRAIN ROW, the effort ring + coupled stat stack

    private var strainCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Day Strain")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let word = strainBandWord {
                        Text(word).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                HStack(alignment: .center, spacing: NoopMetrics.space4) {
                    // The day's strain on the classic 0–21 axis, as the one ring in the Effort colour.
                    ScoreRing(fraction: dayStrain21.map { $0 / 21 },
                              value: dayStrain21.map { String(format: "%.1f", $0) } ?? "—",
                              caption: String(localized: "of 21"),
                              color: StrandPalette.effortColor, diameter: 120)

                    // Right: the coupled stat stack — the OPTIMAL band on the same axis, calories, workouts.
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        optimalStat
                        heroStat(String(localized: "Calories"), caloriesText)
                        heroStat(String(localized: "Workouts"), "\(workoutsToday)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The band word (Light / Moderate / Strenuous / High) the classic StrainGauge drew from the fill
    /// fraction, kept beside the card title so the coupled read still names the effort band.
    private var strainBandWord: String? {
        guard let s = dayStrain21 else { return nil }
        switch s {
        case ..<6:   return String(localized: "Light")
        case ..<10:  return String(localized: "Moderate")
        case ..<14:  return String(localized: "Strenuous")
        default:     return String(localized: "High")
        }
    }

    /// The OPTIMAL strain band: the range as text, and a 0–21 track with the band shaded and today's
    /// strain marked, so "where am I against the band" reads at a glance. A calibrating / unscored day
    /// shows a dash and a bare track.
    private var optimalStat: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text("Optimal").strandLabel()
            Text(Self.optimalStrainRangeText(recovery: recovery))
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    if let band = Self.optimalStrainRange(recovery: recovery) {
                        Capsule()
                            .fill(StrandPalette.chargeColor.opacity(0.45))
                            .frame(width: w * CGFloat(band.upperBound - band.lowerBound) / 21)
                            .offset(x: w * CGFloat(band.lowerBound) / 21)
                    }
                    if let s = dayStrain21 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2)
                            .offset(x: max(0, min(w - 2, w * CGFloat(s / 21))))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A label over a value, for the coupled stat stack.
    private func heroStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(title).strandLabel()
            Text(value).font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active calories for the day from the stored whole-day estimate. Never fabricated, a day with no
    /// estimate reads a dash.
    private var caloriesText: String {
        guard let k = day?.activeKcalEst else { return "—" }
        return "\(Int(k.rounded())) kcal"
    }

    // MARK: 3. SLEEP ROW, the sleep-performance ring + hours-vs-need read (tap = Sleep)

    private var sleepCard: some View {
        NavigationLink {
            SleepView()
        } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sleep performance")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    HStack(alignment: .center, spacing: NoopMetrics.space4) {
                        ScoreRing(fraction: sleepPerformance.map { $0 / 100 },
                                  value: sleepPerformance.map { "\(Int($0.rounded()))" } ?? "—",
                                  color: StrandPalette.restColor, diameter: 72)

                        // Right: the slept-vs-needed two-line read + last night's bed–wake span footnote.
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            if let asleep = day?.totalSleepMin, asleep > 0 {
                                Text("\(Self.hoursMinutes(asleep)) slept")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("\(Self.hoursMinutes(sleepNeedForDay)) needed")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            } else {
                                Text("No sleep tracked last night")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            if let span = bedWakeSpanText {
                                Text(span)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sleepAccessibilityLabel)
        .accessibilityHint("Open Sleep")
    }

    private var sleepAccessibilityLabel: String {
        guard let p = sleepPerformance else { return String(localized: "Sleep performance not available") }
        if let asleep = day?.totalSleepMin, asleep > 0 {
            return String(localized: "Sleep performance \(Int(p.rounded())) percent. \(Self.hoursMinutes(asleep)) slept, \(Self.hoursMinutes(sleepNeedForDay)) needed")
        }
        return String(localized: "Sleep performance \(Int(p.rounded())) percent")
    }

    /// The night's need (minutes) for the slept-vs-needed read: the imported per-day figure when the
    /// export carried one, else the shared ≥ 7.5h personal-mean floor (matches SleepView.sleepNeedMin).
    private var sleepNeedForDay: Double {
        if let need = day.flatMap({ repo.importedSleep[$0.day]?.needMin }), need > 0 { return need }
        return sleepNeedMin
    }

    /// The personal sleep need (minutes): the recent-mean total sleep, never below a 7.5h floor. Byte-for-byte
    /// the same rule as SleepView.sleepNeedMin so the two screens agree.
    private var sleepNeedMin: Double {
        let banked = repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 }
        let mean = banked.isEmpty ? nil : banked.reduce(0, +) / Double(banked.count)
        return Swift.max(450, mean ?? 450)   // 450 min = 7.5h
    }

    /// Last night's bed → wake span, e.g. "23:41 – 07:23", from the day's bridged MAIN-night span
    /// (`SleepView.mainNightSpan`, the SAME resolver the Sleep tab hero and the daily total use), only
    /// when that night actually touches today's window (a days-old import is not "last night"). Was
    /// previously the screen's own "freshest-ending session" pick, which could name a different block —
    /// and so a different span — than the Sleep tab and Today's HR graph for a night stored as more than
    /// one block (#294).
    private var bedWakeSpanText: String? {
        let dayStart = Calendar.current.startOfDay(for: Repository.logicalDay(Date()))
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let candidates = repo.sleeps.filter { $0.endTs > windowStart }
        guard let span = SleepView.mainNightSpan(candidates, habitualMidsleepSec: habitualMidsleepSec)
        else { return nil }
        return "\(clockString(span.start)) - \(clockString(span.end))"
    }

    // MARK: Charge breakdown sheet (the hero tap target)
    //
    // The same "What shaped it" content the Today Charge ring opens: the shared ChargeBreakdownSection over
    // drivers DERIVED from the displayed row (never a second store scan), the honest calibrating countdown
    // while the baseline seeds, and the "How Charge is calculated" method link. TodayView's own sheet is
    // view-private, so this hosts the SAME shared components with the same derivations, no engine work.

    /// The row the breakdown reads, mirroring the hero: today's own when scored, else the carried
    /// last-scored day, so the sheet always matches the ring above it.
    private var breakdownRow: DailyMetric? {
        if let t = day, t.recovery != nil { return t }
        return carriedRecoveryDay
    }

    /// The ordered Charge drivers for the displayed ring PLUS the confidence tier from the SAME folded HRV
    /// baseline — the exact TodayView derivation (pure engine scoring against the folded personal
    /// baselines). nil for a calibrating / cold-start night, which gates the sheet through to the countdown
    /// instead. PERF: mirrors TodayView.chargeBreakdown() — the old `chargeDrivers` property plus the
    /// sheet's inline confidence fold re-folded the full `repo.days` history four times per body eval of
    /// the open sheet; one call now folds each series exactly once, guards before any fold.
    private func chargeBreakdown() -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let row = breakdownRow else { return nil }
        return ChargeBreakdownWiring.breakdown(days: repo.days, row: row, sleepPerfPercent: sleepPerformance,
                                               hrvBaselineEpoch: Baselines.hrvBaselineEpoch(),
                                               recoveryBaselineEpoch: Baselines.recoveryBaselineEpoch(),
                                               dayLogs: BaselineStandard.loadDayLogs())
    }

    @ViewBuilder
    private var chargeBreakdownSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // One chargeBreakdown() call per sheet body eval: drivers + confidence share the same
                    // baseline folds (see chargeBreakdown's PERF note).
                    let breakdown = chargeBreakdown()
                    if let breakdown, !breakdown.drivers.isEmpty {
                        NoopCard {
                            ChargeBreakdownSection(
                                drivers: breakdown.drivers,
                                confidence: breakdown.confidence,
                                skinTempRel: RecoveryScorer.skinTempRelative(deviationC: breakdownRow?.skinTempDevC))
                        }
                    } else {
                        if let banked = calibrationNights {
                            calibrationCard(banked: banked)
                        } else {
                            NoopCard {
                                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                    Text("No Charge breakdown yet")
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("Wear the strap overnight to score a night first.")
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    // The general METHOD behind the score, clearly separated from today's values, exactly
                    // the link the Today breakdown carries. Pushes within this sheet's own NavigationStack.
                    NavigationLink {
                        ScoringGuideView(initialSection: .charge, onClose: { showChargeBreakdown = false })
                    } label: {
                        NoopListSection {
                            NoopListRow(icon: "function", iconColor: StrandPalette.accent,
                                        title: "How Charge is calculated")
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How Charge is calculated. The method behind the score.")
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What shaped your Charge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #endif
            }
        }
    }

    /// The calibrating countdown card, the same pure `ChargeBreakdownFormat` copy the Today sheet shows,
    /// so the two breakdowns read identically while the baseline seeds.
    private func calibrationCard(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Charge"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        return NoopCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(StrandFont.icon(.row))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdown)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        ConfidenceTierChip(confidence: .calibrating)
                    }
                    Text(unlock)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progress)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    // #731: when the countdown restarted because the user tapped "Recalibrate baseline",
                    // say so — otherwise the natural response to a fresh countdown is to tap it again,
                    // which resets it once more. nil (and no line) for anyone who never recalibrated.
                    if let restarted = ChargeBreakdownFormat.currentCalibrationRestartCause() {
                        Text(restarted)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    // MARK: Shared helpers

    private func clockString(_ ts: Int) -> String {
        Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var clockFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// "6h 42m" from a minutes count, for the slept-vs-needed read. Mirror EXACTLY in Kotlin.
    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Swift.max(0, Int(minutes.rounded()))
        return "\(total / 60)h \(total % 60)m"
    }

    // MARK: - OPTIMAL strain range (task #43), pure display-only recovery→strain mapping
    //
    // The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
    // higher optimal band, a red day a lower one. This is PRESENTATION ONLY, it is never fed back into any
    // score or engine; it just tells the user where a "matched" strain would sit on the 0–21 axis. The bands
    // are the APPROVED mapping and MUST stay byte-identical to the Android `optimalStrainRange`:
    //
    //   recovery ≥ 67 (green)       → 14–18 of 21
    //   34 ≤ recovery ≤ 66 (yellow) → 10–14
    //   recovery < 34 (red)         → 4–10
    //
    // nil recovery (calibrating / unscored day) → nil, the caller renders a dash, never a guessed band.

    /// The pure recovery→optimal-strain band. Returns nil when recovery is unknown. Bands per the doc above.
    static func optimalStrainRange(recovery: Double?) -> ClosedRange<Int>? {
        guard let r = recovery else { return nil }
        switch r {
        case 67...:   return 14...18
        case 34..<67: return 10...14
        default:      return 4...10
        }
    }

    /// The optimal band as display text ("14 to 18" / "—"). Byte-identical formatting to Android.
    static func optimalStrainRangeText(recovery: Double?) -> String {
        guard let band = optimalStrainRange(recovery: recovery) else { return "—" }
        return String(localized: "\(band.lowerBound) to \(band.upperBound)")
    }
}

#if DEBUG
#Preview("Coupled view") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: Repository.logicalDayKey(Date()),
            totalSleepMin: 402, efficiency: 92,
            deepMin: 84, remMin: 96, lightMin: 222, disturbances: 6,
            restingHr: 51, avgHrv: 68, recovery: 74, strain: 62,
            exerciseCount: 2,
            spo2Pct: 97, skinTempDevC: 0.1, respRateBpm: 14.4,
            steps: 8200, activeKcalEst: 640
        )
    ]
    repo.loaded = true
    return NavigationStack { CoupledView() }
        .environmentObject(repo)
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}
#endif
