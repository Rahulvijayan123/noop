import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Baseline vital page
//
// One Layer 1 vital against its usual: the scored night's value (or the night under the finger), the
// nights around it against the usual band, the numbers behind the usual, the treatment comparison during a
// logged course, the day's labels, and the method in About.
//
// Reached from a Monitor Baseline row (`TabRoute.baselineVital`, which picks that vital) and from the
// Today Baseline ring (`TabRoute.baselineCharts`, the vital last chosen). `BaselineStore` is one shared
// instance, so the vital, context and as-of night this page steps through are the store's own; the page
// only reads them and calls the store's existing actions. Everything drawn is in the user's unit (°F for
// temperature where chosen, "rpm" for breathing).
struct BaselineVitalPage: View {
    /// `LBSeries.rawValue` of the vital to open, or nil to keep the store's current one.
    var seriesRaw: String? = nil

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var store: BaselineStore
    @EnvironmentObject var router: NavRouter
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var usual: UsualWindow = .week
    @State private var selection: Date?
    @State private var appeared = false
    /// Set when the page appeared before the first nights loaded: the store then set the as-of night from
    /// its demonstration tape, so the first real nights move it to the newest real night.
    @State private var appearedWithoutNights = false
    /// Local, not `store.showContextSheet`: Today and Monitor stay mounted together in the tab bar, and two
    /// sheets bound to one store flag would both try to present.
    @State private var dayLogPresented = false
    /// "Usual by time of day": one evaluation per context for this vital's family, cached per refresh.
    @State private var contextUsuals: [ContextUsual] = []

    /// Which usual the page draws and judges against. Not a calendar range: "This week" is the 7-night
    /// usual around the scored night, "60 days" the slow usual rebuilt week by week.
    enum UsualWindow: String, CaseIterable, Hashable {
        case week, long
        var label: String { self == .week ? "This week" : "60 days" }
    }

    private var days: [DailyMetric] { store.displayDays(from: repo.days) }
    private var requestedSeries: LBSeries? { seriesRaw.flatMap(LBSeries.init(rawValue:)) }

    private var fahrenheit: Bool {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw) == .fahrenheit
    }

    private var series: LBSeries { store.series }
    private var planUnit: String { series.planRow.unit }
    private var unit: String { MonitorLabels.unit(planUnit, fahrenheit: fahrenheit) }
    private func show(_ native: Double) -> Double {
        MonitorLabels.displayValue(native, planUnit: planUnit, fahrenheit: fahrenheit)
    }
    private func fmt(_ value: Double?) -> String? { value.map { MonitorLabels.number($0, unit: unit) } }

    /// Before the first load, or before the first score of this vital.
    /// Also while the first real nights have arrived but not yet been scored (the page appeared before
    /// them, on the store's demonstration tape, which is never drawn).
    private var loading: Bool {
        !repo.loaded || store.evaluation == nil || (appearedWithoutNights && !repo.days.isEmpty)
    }
    /// No real nights: the store scores a labelled demonstration tape for an empty repository, which this
    /// page never draws.
    private var noNights: Bool { repo.loaded && repo.days.isEmpty }

    private var title: String {
        let name = store.shortTitle(for: series)
        return store.context == .sleep ? name : "\(name), \(MonitorLabels.contextName(store.context).lowercased())"
    }

    // MARK: The selected usual

    private var points: [BaselinePlotPoint] { usual == .week ? store.weekPoints : store.longPoints }
    private var copy: LBCopySnapshot? {
        usual == .week ? (store.evaluation?.show7 == true ? store.evaluation?.copy7 : nil) : store.longCopyForPlot()
    }
    private var verdict: String { usual == .week ? store.shortVerdict : store.longVerdict }
    private var confidencePct: Int? { usual == .week ? store.shortConfidence : store.longConfidence }
    private var asOfKey: String { usual == .week ? store.asOf : store.longAsOf }
    private var scoredValue: Double? {
        (usual == .week ? store.evaluation : (store.longEvaluation ?? store.evaluation))?.todayNative
    }
    private var frozen: Bool { store.evaluation?.trial.trialFreezeOk == true }
    /// What the band is called: the usual, or after a treatment start, the expected path without it.
    private var bandName: String { usual == .long && frozen ? "Expected without treatment" : "Usual range" }

    private var band: ClosedRange<Double>? {
        guard let copy else { return nil }
        let a = show(copy.bandLoDisplay), b = show(copy.bandHiDisplay)
        return min(a, b)...max(a, b)
    }

    private var nightPoints: [DailyPoint] {
        points.compactMap { p in
            guard let v = p.value else { return nil }
            return DailyPoint(key: p.day, value: show(v), isEstimate: p.explained)
        }
    }

    /// Nights outside the drawn band, logged-event nights aside (they are not used to judge).
    private var offPoints: [DailyPoint] {
        guard let band else { return [] }
        return points.compactMap { p in
            guard let v = p.value, !p.explained, !band.contains(show(v)) else { return nil }
            return DailyPoint(key: p.day, value: show(v))
        }
    }

    private var window: ClosedRange<Date> {
        let cal = Calendar.current
        let end = ChartDay.date(forKey: asOfKey).flatMap { cal.dateInterval(of: .day, for: $0)?.end } ?? Date()
        let start = cal.date(byAdding: .day, value: -(usual == .week ? 8 : 61), to: end) ?? end
        return start...end
    }

    private var minSpan: Double {
        switch unit {
        case "bpm": return 10
        case "ms": return 20
        case "rpm": return 3
        case "%": return 4
        case "°C": return 1
        case "°F": return 2
        case "steps": return 2_000
        default: return 1
        }
    }

    private var chartState: ChartState {
        if loading { return .loading }
        if noNights { return .empty("No nights yet") }
        if nightPoints.isEmpty {
            let need = store.nightsNeeded(for: series)
            return .empty(need > 0 ? "Needs \(need) more night\(need == 1 ? "" : "s")" : "No readings in this window")
        }
        return .ready
    }

    private var legend: [ChartLegendItem] {
        var items: [ChartLegendItem] = []
        if band != nil { items.append(ChartLegendItem(.band(StrandPalette.textTertiary), bandName)) }
        if !offPoints.isEmpty { items.append(ChartLegendItem(.point(StrandPalette.statusWarning), "Off usual")) }
        if points.contains(where: { $0.explained && $0.value != nil }) {
            items.append(ChartLegendItem(.estimate(StrandPalette.textPrimary), "Logged event"))
        }
        return items
    }

    // MARK: Readout

    private var selectedPoint: BaselinePlotPoint? {
        guard let selection else { return nil }
        let key = ChartDay.key(for: selection)
        return points.first { $0.day == key }
    }

    private func relation(_ value: Double) -> String? {
        guard let band else { return nil }
        if value > band.upperBound { return "Above \(usual == .long && frozen ? "expected" : "usual")" }
        if value < band.lowerBound { return "Below \(usual == .long && frozen ? "expected" : "usual")" }
        return usual == .long && frozen ? "Within expected range" : "Within usual range"
    }

    private var readout: ReadoutContent {
        if let point = selectedPoint, let day = ChartDay.date(forKey: point.day) {
            let value = point.value.map(show)
            let context: String? = {
                guard let value else { return "No reading" }
                if point.explained { return "Logged event" }
                return relation(value)
            }()
            return ReadoutContent(dateLine: ReadoutContent.dateLine(day, period: .day),
                                  value: fmt(value), unit: unit, context: context)
        }
        let date = ChartDay.date(forKey: asOfKey).map { ReadoutContent.dateLine($0, period: .day) } ?? " "
        if noNights {
            return ReadoutContent(dateLine: " ", value: nil, unit: unit, context: "No nights yet")
        }
        let context: String
        if let band {
            context = "\(usual == .long && frozen ? "Expected" : "Usual") \(MonitorLabels.range(band.lowerBound, band.upperBound, unit: unit)) · \(MonitorLabels.verdict(verdict))"
        } else {
            let need = store.nightsNeeded(for: series)
            context = need > 0 ? "Needs \(need) more night\(need == 1 ? "" : "s") for a usual" : MonitorLabels.verdict(verdict)
        }
        return ReadoutContent(dateLine: date, value: fmt(scoredValue.map(show)), unit: unit, context: context)
    }

    // MARK: Statistics

    private var stats: [StatItem] {
        let off = offPoints.count
        let nights = copy?.n
        return [
            StatItem(usual == .long && frozen ? "Expected" : "Usual", value: fmt(copy.map { show($0.centerDisplay) }),
                     unit: unit),
            StatItem("Range", value: band.map { "\(MonitorLabels.number($0.lowerBound, unit: unit))–\(MonitorLabels.number($0.upperBound, unit: unit))" },
                     unit: unit),
            StatItem("Confidence", value: MonitorLabels.confidence(confidencePct),
                     detail: nights.map { "\($0) night\($0 == 1 ? "" : "s")" }),
            StatItem("Off usual", value: band == nil ? nil : "\(off)", unit: band == nil ? nil : (off == 1 ? "night" : "nights")),
        ]
    }

    // MARK: Body

    var body: some View {
        page
            #if os(iOS)
            .toolbarTitleMenu { vitalMenu }
            #endif
            .onAppear {
                // A Monitor row opens its own vital first, exactly as its tap used to before the push, so the
                // first rescore below keeps it selected even while it is still learning.
                if !appeared, let requested = requestedSeries {
                    store.openVital(requested, days: store.displayDays(from: repo.days))
                }
                appeared = true
                appearedWithoutNights = repo.days.isEmpty
                let tape = days
                if store.evaluation == nil, let last = tape.last?.day {
                    store.asOf = last
                    store.longAsOf = last
                }
                store.rescore(days: tape, preferReadySeries: !store.consumeSeriesPin())
                #if DEBUG
                if MonitorDemoHooks.longWindow { usual = .long }
                if MonitorDemoHooks.sheet == "daylog" { dayLogPresented = true }
                #endif
            }
            // A synced night has to move the usuals without leaving and re-entering the page.
            .onChangeCompat(of: repo.refreshSeq) { _ in
                let firstNights = appearedWithoutNights && !repo.days.isEmpty
                if firstNights { store.jumpToNewestNight(days: days) }
                // Keep the vital this page shows: a sync must not swap a learning vital for a ready one
                // under the reader (the first score on appear still prefers a ready vital).
                store.rescore(days: days, preferReadySeries: false)
                if firstNights { appearedWithoutNights = false }
            }
            .onChangeCompat(of: usual) { _ in selection = nil }
            .task(id: contextUsualsKey) { refreshContextUsuals() }
            .sheet(isPresented: $dayLogPresented, onDismiss: { store.showContextSheet = false }) {
                BaselineDayLogSheet(days: store.displayDays(from: repo.days))
                    .environmentObject(store)
            }
    }

    @ViewBuilder private var page: some View {
        #if os(macOS)
        ScreenScaffold(title: LocalizedStringKey(title), titleDisplay: .navigationBar,
                       trailing: { Menu { vitalMenu } label: { Text("Vital") }.fixedSize() }) {
            content
        }
        #else
        ScreenScaffold(title: LocalizedStringKey(title), titleDisplay: .navigationBar) {
            content
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        ValueReadout(readout, isScrubbing: selection != nil, isLoading: loading)
        SegmentedPillControl(UsualWindow.allCases, selection: $usual, fillsAvailableWidth: true) { $0.label }
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                PeriodStepper(
                    title: stepperTitle,
                    canGoBack: !noNights && (usual == .week ? store.canShift(-1, days: days) : store.canShiftLongWeek(-1, days: days)),
                    canGoForward: !noNights && (usual == .week ? store.canShift(1, days: days) : store.canShiftLongWeek(1, days: days)),
                    onBack: {
                        selection = nil
                        if usual == .week { store.shiftDay(-1, days: days) } else { store.shiftLongWeek(-1, days: days) }
                    },
                    onForward: {
                        selection = nil
                        if usual == .week { store.shiftDay(1, days: days) } else { store.shiftLongWeek(1, days: days) }
                    })
                    .loadingPlaceholder(loading)
                DailyLineChart(
                    series: [.init(id: "nights", name: store.shortTitle(for: series), color: StrandPalette.textPrimary,
                                   points: noNights ? [] : nightPoints),
                             .init(id: "off", name: "Off usual", color: StrandPalette.statusWarning,
                                   points: noNights ? [] : offPoints)],
                    cadence: .daily, interpolation: .linear,
                    typicalBand: noNights ? nil : band, bandColor: StrandPalette.textTertiary,
                    baseline: noNights ? nil : copy.map { ChartReference(show($0.centerDisplay),
                                                                          label: fmt(show($0.centerDisplay))) },
                    legend: legend, state: chartState, window: window,
                    xStyle: usual == .week ? .weekday : .dayOfMonth,
                    y: ChartValueAxis(unit: unit, domain: .fitted(minSpan: minSpan),
                                      format: MonitorLabels.decimals(forUnit: unit) == 0
                                        ? ChartValueAxis.integer : ChartValueAxis.decimals(1)),
                    selection: $selection, accessibilityTitle: store.shortTitle(for: series))
            }
        }
        if frozen, !noNights { treatmentSection }
        if family != nil, !noNights { timeOfDaySection }
        StatGrid(noNights ? stats.map { StatItem($0.label, value: nil) } : stats, columns: 2, isLoading: loading)
        labelsSection
        AboutDisclosure("About \(store.shortTitle(for: series))", paragraphs: aboutParagraphs)
    }

    private var stepperTitle: String {
        guard !noNights, let day = ChartDay.date(forKey: asOfKey) else { return usual == .week ? "This week" : "60 days" }
        let date = ReadoutContent.dateLine(day, period: .day)
        return usual == .week ? "Week to \(date)" : "60 days to \(date)"
    }

    // MARK: Vital menu

    @ViewBuilder private var vitalMenu: some View {
        ForEach(MonitorLabels.contextOrder, id: \.self) { context in
            Section(MonitorLabels.contextName(context)) {
                ForEach(MonitorLabels.series(in: context), id: \.rawValue) { candidate in
                    Button { pick(candidate, in: context) } label: {
                        if candidate == series && context == store.context {
                            Label(store.shortTitle(for: candidate), systemImage: "checkmark")
                        } else {
                            Text(store.shortTitle(for: candidate))
                        }
                    }
                }
            }
        }
    }

    /// The store's own two actions, in the order the old context control and chips ran them.
    private func pick(_ next: LBSeries, in context: BaselineStore.ContextFilter) {
        selection = nil
        if store.context != context { store.selectContext(context, days: days) }
        if store.series != next { store.selectSeries(next, days: days) }
    }

    // MARK: Usual by time of day

    /// One context's usual for this vital: the band and the latest value it was judged on.
    struct ContextUsual: Identifiable, Equatable {
        let context: BaselineStore.ContextFilter
        let series: LBSeries
        let band: ClosedRange<Double>?
        let latest: Double?
        let nights: Int
        var id: String { series.rawValue }
    }

    /// The same vital in each context, where the store has one (heart rate, HRV, SpO₂). Temperature and
    /// breathing are night-only.
    private var family: [(BaselineStore.ContextFilter, LBSeries)]? {
        switch series {
        case .sleepRHR, .awakeRestHR, .awakeActiveHR, .continuousHR:
            return [(.sleep, .sleepRHR), (.rest, .awakeRestHR), (.active, .awakeActiveHR), (.allDay, .continuousHR)]
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn:
            return [(.sleep, .sleepHRVLn), (.rest, .awakeRestHRVLn), (.active, .awakeActiveHRVLn), (.allDay, .continuousHRVLn)]
        case .sleepSpO2Mean, .awakeRestSpO2Mean, .awakeActiveSpO2Mean, .continuousSpO2Mean:
            return [(.sleep, .sleepSpO2Mean), (.rest, .awakeRestSpO2Mean), (.active, .awakeActiveSpO2Mean),
                    (.allDay, .continuousSpO2Mean)]
        default:
            return nil
        }
    }

    private var contextUsualsKey: String {
        "\(repo.refreshSeq)|\(store.asOf)|\(family?.first?.1.rawValue ?? "-")|\(repo.days.count)"
    }

    /// The existing Layer 1 evaluation, once per context, for display only (nothing is stored).
    private func refreshContextUsuals() {
        guard let family, !repo.days.isEmpty else {
            contextUsuals = []
            return
        }
        let tape = days
        let asOf = store.asOf
        contextUsuals = family.map { context, member in
            let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: member,
                                                   observations: store.observations(from: tape, series: member),
                                                   trial: LBTrialRequest.none)
            let copy = ev.show7 ? ev.copy7 : (ev.showLong ? ev.copyLong : nil)
            return ContextUsual(context: context, series: member,
                                band: copy.map { min($0.bandLoDisplay, $0.bandHiDisplay)...max($0.bandLoDisplay, $0.bandHiDisplay) },
                                latest: ev.todayNative, nights: ev.n7)
        }
    }

    @ViewBuilder private var timeOfDaySection: some View {
        let rows = contextUsuals
        let values = rows.flatMap { row in [row.band?.lowerBound, row.band?.upperBound, row.latest].compactMap { $0 } }
        let domain: ClosedRange<Double> = {
            guard let lo = values.min(), let hi = values.max() else { return 0...1 }
            let pad = max((hi - lo) * 0.08, minSpan * 0.1)
            return (lo - pad)...(hi + pad)
        }()
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Usual by time of day")
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { NoopListDivider() }
                        Button { pick(row.series, in: row.context) } label: {
                            contextRow(row, domain: domain)
                        }
                        .buttonStyle(LiquidPressStyle())
                    }
                }
            }
            .loadingPlaceholder(rows.isEmpty)
        }
    }

    private func contextRow(_ row: ContextUsual, domain: ClosedRange<Double>) -> some View {
        let current = row.series == series && row.context == store.context
        let need = max(0, LongitudinalBaseline.Params.n7Show - row.nights)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(MonitorLabels.contextName(row.context))
                    .font(StrandFont.body.weight(current ? .semibold : .regular))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Text(row.band.map { MonitorLabels.range(show($0.lowerBound), show($0.upperBound), unit: unit) }
                     ?? "Learning · \(row.nights) of \(LongitudinalBaseline.Params.n7Show) \(row.context == .sleep ? "nights" : "days")")
                    .font(StrandFont.subhead)
                    .foregroundStyle(row.band == nil ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if row.band != nil || row.latest != nil {
                RangeStrip(domain: show(domain.lowerBound)...show(domain.upperBound),
                           band: row.band.map { show($0.lowerBound)...show($0.upperBound) },
                           marker: row.latest.map(show),
                           markerColor: row.latest.flatMap { latest in row.band.map { $0.contains(latest) } } == false
                               ? StrandPalette.statusWarning : StrandPalette.textPrimary)
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(need > 0 ? "" : "Shows this usual")
    }

    // MARK: Treatment

    @ViewBuilder private var treatmentSection: some View {
        let trial = store.evaluation?.trial
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Treatment", trailing: trial?.displayName)
            StatGrid([
                StatItem("Without treatment", value: fmt(trial?.expectedUntreatedDisplay.map(show)), unit: unit),
                StatItem(trial?.displayName.map { "On \($0)" } ?? "On treatment",
                         value: fmt(store.evaluation?.copyLong.map { show($0.centerDisplay) }), unit: unit),
                StatItem("Latest", value: fmt(store.evaluation?.todayNative.map(show)), unit: unit),
            ], columns: 3)
            let lines = treatmentLines
            if !lines.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var treatmentLines: [String] {
        guard let trial = store.evaluation?.trial else { return [] }
        var out: [String] = []
        if trial.phase == .washingOut {
            out.append("Washing out · you entered \(trial.washoutDaysUsed) days after the last dose")
        }
        if trial.tooEarly { out.append("Too early to judge a response") }
        if let line = trial.summarySentence { out.append(line) }
        if store.isExploratory(series) { out.append("Exploratory: not one of this course's watched vitals") }
        return out
    }

    // MARK: Labels

    private var labelsSection: some View {
        let logged = store.calendarTodayLog
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Labels")
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    Button {
                        store.openDayLog(on: store.calendarTodayKey)
                        dayLogPresented = true
                    } label: {
                        NoopListRow(icon: "square.and.pencil", iconColor: StrandPalette.accent, title: "Daily log",
                                    subtitle: logged?.summaryLine, value: logged == nil ? "Not logged today" : "Saved")
                    }
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    Button { router.openTreatment() } label: {
                        NoopListRow(icon: "cross.case", iconColor: StrandPalette.accent, title: "Treatment",
                                    subtitle: store.activeStart == nil ? nil : store.medicationLabelToday.wearerLine,
                                    value: store.activeStart?.bannerName ?? "None")
                    }
                }
                .buttonStyle(LiquidPressStyle())
            }
        }
    }

    // MARK: About

    private var aboutParagraphs: [String] {
        let name = store.shortTitle(for: series)
        var out = [
            "Your usual is the range \(name) normally sits in, built from your own nights. This week's usual is made from the nights around the scored night; that night itself is not folded in. The 60-day usual moves slowly and is rebuilt week by week from the 60-day median.",
        ]
        if let ev = store.evaluation {
            out.append(String(format: "Built from nights without a logged event (%@). The band reaches %.2f spreads either side of the usual.",
                              ev.stableWindow.caption.lowercased(), ev.kBandUsed))
            out.append(ev.slopeUsable ? "The longer usual may drift slowly; a short spike does not move it."
                                      : "The 60-day usual is rebuilt each week from that week's 60-day median.")
        }
        if let trust = confidencePct {
            var line = "Confidence comes from how many nights the usual rests on and how steady they are: \(trust) % trust."
            if usual == .week, let howOff = store.shortHowOff { line += " The scored night sat \(howOff) % of the way to unusual." }
            out.append(line)
        }
        out.append("Nights with a logged event are drawn hollow. They stay visible and are not used to judge a treatment response. Nights shown in amber are outside the band.")
        if let trial = store.evaluation?.trial, frozen {
            if let ghost = trial.gapVsFlatDisplay, trial.flatModelOnly != true {
                out.append(String(format: "Against the old flat usual it would look like %.1f %@.", ghost, unit))
            }
            if trial.flatModelOnly == true {
                out.append("There is not enough pre-start trend to project, so the comparison uses the usual level only.")
            }
            out.append(trial.disclaimer.isEmpty ? LongitudinalBaseline.reviewDisclaimer : trial.disclaimer)
        }
        out.append("Method: \(series.planRow.planName).")
        out.append("Not a diagnosis. Separate from Charge.")
        return out
    }
}
