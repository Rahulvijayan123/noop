import SwiftUI
import Charts
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights Hub (v5)
//
// The headline n-of-1 "what actually moves YOUR recovery" surface. Two halves, both
// pure association on the user's own logged days — never advice, diagnosis, or cause:
//
//  1. WHAT MOVES YOUR CHARGE — the unified, LAG-AWARE EffectRanker feed. For each
//     journal behaviour × the selected outcome it keeps the strongest honest lag
//     ({0,+1,+2} days), so each row reads "shows up the next morning" rather than
//     pretending everything is same-day. Each card carries the sign-aware sentence,
//     with/without means, a lead/lag chip, the effect-size word, and a Solid /
//     Building / Calibrating confidence pill — NOT a bare "significant" stamp.
//
//  2. ALCOHOL / CAFFEINE DOSE-RESPONSE — the personal DoseResponseEngine curve. A
//     per-user slope that SHRINKS toward a documented population prior until enough
//     nights accrue. The card plots the shrunk curve, states "each extra drink ≈ −N
//     for you" (honest when still prior-dominated, or when YOUR data contradicts the
//     prior), and an evening "damage forecast" preview — "a 2nd drink tonight ≈ −X
//     Charge tomorrow" — composed from the curve's per-unit Δ on the latest Charge.
//
// SELF-CONTAINED: this screen owns its own load/derive (InsightsHubViewModel) and takes
// the Repository via @EnvironmentObject — it does NOT edit AppModel / the central nav.
// Wave 3 surfaces it as the head of the Insights hub (see 'wiringNeeded').
//
// All maths lives in StrandAnalytics (EffectRanker / DoseResponseEngine / DoseResponsePriors);
// this view loads the series, shapes the engine inputs, and presents honestly.

struct InsightsHubView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()

    /// The currently-selected outcome for the ranked feed (Charge / HRV / Rest / Resting HR).
    @State private var outcome: InsightsHubViewModel.Outcome = .recovery

    var body: some View {
        ScreenScaffold(title: "What moves you", titleDisplay: .navigationBar, isLoading: !model.loaded) {
            moversSection
            doseSection
            AboutDisclosure("How to read this", paragraphs: [
                String(localized: "Everything here is a pattern in your own logged days: an association with an effect size and confidence, never a cause or a diagnosis. Population patterns are shown as \u{201C}typical\u{201D} and are always overridden by your own data once you have enough of it. Approximations, not WHOOP\u{2019}s scores; not a medical device."),
            ])
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .onChangeCompat(of: outcome) { model.rankFor($0) }
    }

    // MARK: - What moves your Charge (ranked, lag-aware)

    private var moversSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What moves your \(outcome.outcomeName.lowercased())")
            SegmentedPillControl(InsightsHubViewModel.Outcome.allCases, selection: $outcome,
                                 fillsAvailableWidth: true) { $0.label }
                .accessibilityLabel("Outcome metric")

            if model.loaded && model.ranked.isEmpty {
                ComingSoon(what: "Log behaviours in your journal. After a few days with and without each one, Nara ranks how it moves your charge, HRV and rest.")
            } else {
                NoopListSection {
                    ForEach(Array(model.ranked.enumerated()), id: \.offset) { index, ranked in
                        if index > 0 { NoopListDivider() }
                        InsightsDetailLink {
                            MoverDetailPage(ranked: ranked, outcome: outcome)
                        } label: {
                            moverRow(ranked)
                        }
                    }
                }
            }
        }
    }

    /// One ranked, lag-aware mover: the behaviour, its signed effect on the outcome in the outcome's
    /// units, when it shows up and how sure the read is.
    private func moverRow(_ r: RankedEffect) -> some View {
        let e = r.effect
        let movedGood: Bool? = e.delta == 0 ? nil : ((e.delta > 0) == outcome.higherIsBetter)
        let tone: StrandTone = movedGood.map { $0 ? .positive : .warning } ?? .neutral
        return NoopListRow(icon: nil, title: LocalizedStringKey(r.behavior),
                           subtitle: "\(r.leadLagText) · \(Self.confidenceWord(r.confidence))",
                           value: outcome.signedDelta(e.delta), valueTone: tone)
            .accessibilityElement(children: .ignore)
            // One whole-string key; the args are complete sentences, never concatenated tails.
            .accessibilityLabel(String(localized: "\(r.sentence()) Cohen's d \(String(format: "%.2f", e.cohensD)). \(Self.scoreState(r.confidence).accessibilityWord)"))
    }

    // MARK: - Alcohol / caffeine dose-response

    private var doseSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Dose-response")
            if model.loaded && model.doseCards.isEmpty {
                ComingSoon(what: "Log alcohol or late caffeine with an amount and Nara fits a personal dose curve.")
            } else {
                ForEach(model.doseCards) { card in
                    DoseResponseCardView(card: card)
                }
            }
        }
    }

    // MARK: - Helpers

    static func confidenceWord(_ c: ScoreConfidence) -> String {
        switch c {
        case .solid:       return String(localized: "Solid")
        case .building:    return String(localized: "Building")
        case .calibrating: return String(localized: "Calibrating")
        }
    }

    /// Map the engine's ScoreConfidence tier to the design-system ScoreState (VoiceOver wording).
    static func scoreState(_ c: ScoreConfidence) -> ScoreState {
        switch c {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }

    /// Cohen's d → conventional magnitude word.
    static func effectMagnitudeWord(_ d: Double) -> String {
        switch abs(d) {
        case ..<0.2: return String(localized: "negligible")
        case ..<0.5: return String(localized: "small")
        case ..<0.8: return String(localized: "moderate")
        default:     return String(localized: "large")
        }
    }
}

private extension ScoreState {
    /// VoiceOver-only certainty phrase for a mover row.
    var accessibilityWord: String {
        switch self {
        case .solid:       return String(localized: "Solid signal.")
        case .building:    return String(localized: "Building. Keep logging.")
        case .calibrating: return String(localized: "Calibrating. Too thin to read yet.")
        case .live:        return ""
        }
    }
}

// MARK: - One mover, in detail

/// A behaviour's effect on the selected outcome, one tap below its row: the engine's sentence, the
/// outcome with and without it on one axis, the effect size, and how sure the read is.
private struct MoverDetailPage: View {
    let ranked: RankedEffect
    let outcome: InsightsHubViewModel.Outcome

    var body: some View {
        let e = ranked.effect
        let movedGood = e.delta == 0 ? nil : ((e.delta > 0) == outcome.higherIsBetter)
        let color = movedGood.map { $0 ? StrandPalette.statusPositive : StrandPalette.statusWarning }
            ?? StrandPalette.textSecondary
        ScreenScaffold(title: LocalizedStringKey(ranked.behavior), titleDisplay: .navigationBar) {
            ValueReadout(ReadoutContent(dateLine: ranked.leadLagText,
                                        value: outcome.signedDelta(e.delta, includeUnit: false),
                                        unit: outcome.unit,
                                        context: "\(outcome.outcomeName) · \(InsightsHubView.confidenceWord(ranked.confidence))"))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text(ranked.sentence())
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    InsightsComparisonBars(bars: [
                        .init(id: "with", label: String(localized: "With"), value: e.meanWith,
                              valueText: outcome.format(e.meanWith), detail: "n = \(e.nWith)", color: color),
                        .init(id: "without", label: String(localized: "Without"), value: e.meanWithout,
                              valueText: outcome.format(e.meanWithout), detail: "n = \(e.nWithout)",
                              color: StrandPalette.textTertiary),
                    ], domain: outcome.axis(e.meanWith, e.meanWithout))
                }
            }
            StatGrid([
                StatItem(String(localized: "Effect size"), value: String(format: "%.2f", e.cohensD),
                         detail: InsightsHubView.effectMagnitudeWord(e.cohensD)),
                StatItem(String(localized: "Days logged"), value: "\(e.nWith + e.nWithout)",
                         detail: "\(e.nWith) · \(e.nWithout)"),
            ])
            AboutDisclosure(paragraphs: [
                String(localized: "Effect size is Cohen's d: the difference between the two groups in units of their spread. Around 0.2 is small, 0.5 moderate and 0.8 large."),
                String(localized: "Everything here is a pattern in your own logged days: an association with an effect size and confidence, never a cause or a diagnosis. Population patterns are shown as \u{201C}typical\u{201D} and are always overridden by your own data once you have enough of it. Approximations, not WHOOP\u{2019}s scores; not a medical device."),
            ])
        }
    }
}

// MARK: - Dose-response card
//
// The headline alcohol/caffeine surface: the prior-shrunk curve, the per-unit read,
// the confidence pill, the honesty note, and an evening "damage forecast" preview
// driven by a dose picker (or a tap on the curve). The forecast is a what-if on the user's own latest
// Charge — "a 2nd drink tonight tends to line up with about −7 on tomorrow's Charge
// for you" — never a recommendation to drink or abstain.

private struct DoseResponseCardView: View {
    let card: InsightsHubViewModel.DoseCard

    /// The "what if I have one more" preview dose, defaulting to one above the typical
    /// starting point so the headline reads as a 2nd-drink forecast out of the box.
    @State private var previewDose: Int = 2

    private var accent: Color { card.outcomeName == "HRV" ? StrandPalette.metricPurple : StrandPalette.chargeColor }

    var body: some View {
        let r = card.response
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: card.symbol)
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(card.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    InsightsConfidencePill(confidence: r.confidence)
                }

                // The engine's honest read sentence (prior / yours / contradicts-prior).
                Text(r.sentence())
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The prior-shrunk curve: each dose on x, the modelled change on y in the outcome's unit.
                // A tap on a dose sets the forecast below.
                DoseCurveChart(card: card, accent: accent, selectedDose: $previewDose)
                    .accessibilityLabel(curveAccessibilityLabel(r))

                if r.priorDominated {
                    InlineNotice(String(localized: "Based mostly on typical patterns, not yet yours. Log a few more \(card.unitLabel.lowercased()) days and this becomes yours."),
                                 placement: .inCard)
                } else if r.contradictsPrior {
                    InlineNotice(String(localized: "In your data so far, this doesn\u{2019}t move your \(card.outcomeName) the way it typically does."),
                                 tone: .positive, placement: .inCard)
                }

                if card.timingProxy {
                    Text("\u{201C}Dose\u{201D} here is timing (later in the day = stronger), not milligrams.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle().fill(StrandPalette.hairline).frame(height: NoopMetrics.hairlineWidth)

                damageForecast(r)
            }
        }
    }

    // MARK: Evening damage forecast (what-if on the user's latest Charge)

    @ViewBuilder private func damageForecast(_ r: DoseResponse) -> some View {
        // The Δ of going from the typical starting dose (1) to the previewed dose, applied
        // to the user's most recent outcome value as an honest "where you'd likely land".
        let fromDose = 1
        let delta = r.delta(fromDose: fromDose, toDose: previewDose)
        let projected = card.latestOutcome.map { max(0, min(card.outcomeCeiling, $0 + delta)) }
        let stepLabel = previewDose <= 1 ? String(localized: "no extra") : card.stepLabel(previewDose)

        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text(card.forecastOverline)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            SegmentedPillControl(card.doseChoices, selection: $previewDose, fillsAvailableWidth: true) {
                card.doseChoiceLabel($0)
            }
            .accessibilityLabel("Preview dose")

            Text(forecastSentence(delta: delta, projected: projected, stepLabel: stepLabel))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            InsightsValueRow(label: String(localized: "Per extra \(card.unitNoun)"),
                             value: signed(r.perUnit, suffix: card.outcomeSuffix))
            InsightsValueRow(label: String(localized: "Tomorrow\u{2019}s \(card.outcomeName)"),
                             value: projected.map { "\(Int($0.rounded()))\(card.outcomeSuffix)" } ?? "—")
        }
    }

    /// Whole-phrase variants per direction and basis, so translators never see stitched
    /// lower/higher or basis fragments.
    private func forecastSentence(delta: Double, projected: Double?, stepLabel: String) -> String {
        if previewDose <= 1 {
            return String(localized: "No extra tonight. Your \(card.outcomeName.lowercased()) forecast stays where it is.")
        }
        let magText = "\(Int(abs(delta).rounded()))\(card.outcomeSuffix)"
        let lower = delta <= 0
        if card.response.priorDominated {
            return lower
                ? String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) lower on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on typical patterns.")
                : String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) higher on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on typical patterns.")
        }
        return lower
            ? String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) lower on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on \(card.response.nUser) of your \(card.unitLabel.lowercased()) days.")
            : String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) higher on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on \(card.response.nUser) of your \(card.unitLabel.lowercased()) days.")
    }

    private func signed(_ v: Double, suffix: String) -> String {
        let mag = abs(v)
        let rounded = (mag * 10).rounded() / 10
        let sign = v < 0 ? "−" : (v > 0 ? "+" : "")
        // Show whole numbers without a trailing .0 for the small Charge magnitudes.
        let body = rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        return "\(sign)\(body)\(suffix)"
    }

    /// Whole-string key per variant (never a concatenated localized tail on an a11y label).
    private func curveAccessibilityLabel(_ r: DoseResponse) -> String {
        r.priorDominated
            ? String(localized: "Dose-response curve. Each extra \(card.unitNoun) lines up with about \(signed(r.perUnit, suffix: card.outcomeSuffix)) on \(card.outcomeName), typical patterns.")
            : String(localized: "Dose-response curve. Each extra \(card.unitNoun) lines up with about \(signed(r.perUnit, suffix: card.outcomeSuffix)) on \(card.outcomeName), your own data.")
    }
}

// MARK: - Dose curve chart
//
// The prior-shrunk curve on Swift Charts: each dose a labelled category on x (the dose picker's own
// labels), the modelled outcome CHANGE on y in the outcome's unit, a dashed zero rule, straight segments
// between the doses. A curve that is still mostly the population prior is drawn dashed with hollow
// points and named "Typical" in its legend (estimates are hollow, never a different hue). A tap on a
// dose selects it for the forecast.

private struct DoseCurveChart: View {
    let card: InsightsHubViewModel.DoseCard
    let accent: Color
    @Binding var selectedDose: Int

    var body: some View {
        let points = card.response.curve
        let typical = card.response.priorDominated
        let maxAbs = max(1.0, points.map { abs($0.outcomeDelta) }.max() ?? 1.0)
        let unit = card.outcomeName == "HRV" ? "ms" : "%"
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(NaraChartStyle.referenceColor)
                    .lineStyle(NaraChartStyle.reference)
                ForEach(points, id: \.dose) { point in
                    LineMark(x: .value("Dose", card.doseChoiceLabel(point.dose)),
                             y: .value("Change", point.outcomeDelta))
                        .foregroundStyle(accent)
                        .lineStyle(typical ? NaraChartStyle.estimateLine : NaraChartStyle.line)
                        .interpolationMethod(.linear)
                    PointMark(x: .value("Dose", card.doseChoiceLabel(point.dose)),
                              y: .value("Change", point.outcomeDelta))
                        .symbol {
                            Circle()
                                .strokeBorder(accent, lineWidth: NaraChartStyle.estimateStroke)
                                .background(Circle().fill(typical ? StrandPalette.surfaceRaised : accent))
                                .frame(width: point.dose == selectedDose ? 10 : 7,
                                       height: point.dose == selectedDose ? 10 : 7)
                        }
                }
            }
            .chartYScale(domain: -maxAbs * 1.15 ... maxAbs * 1.15)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(NaraChartStyle.axisFont).foregroundStyle(NaraChartStyle.axisColor)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                    AxisValueLabel().font(NaraChartStyle.axisFont).foregroundStyle(NaraChartStyle.axisColor)
                }
            }
            .chartYAxisLabel(position: .top, alignment: .leading) {
                Text("Δ \(unit)").font(NaraChartStyle.unitFont).foregroundStyle(StrandPalette.textSecondary)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            let plot = proxy.plotRectCompat(in: geo)
                            let x = location.x - plot.minX
                            if let label: String = proxy.value(atX: x),
                               let dose = card.doseChoices.first(where: { card.doseChoiceLabel($0) == label }) {
                                selectedDose = dose
                            }
                        }
                }
            }
            .frame(height: NoopMetrics.chartHeightSecondary)
            if typical {
                ChartLegend([ChartLegendItem(.estimate(accent), String(localized: "Typical"))])
            }
        }
    }
}

// MARK: - View-model
//
// Self-contained: loads the journal (behaviour → days), dose rows (under the dedicated
// noop-journal-dose source), and the outcome series (imported metricSeries ∪ DailyMetric
// fallback, exactly as InsightsView), then runs EffectRanker for the ranked feed and
// DoseResponseEngine for each dosed behaviour the user has data for. No edits to AppModel.

@MainActor
final class InsightsHubViewModel: ObservableObject {

    // MARK: Outcome

    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return String(localized: "Resting HR")
            }
        }
        /// metricSeries key.
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The engine's outcome label (carried onto each RankedEffect).
        var outcomeName: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return String(localized: "Resting HR")
            }
        }
        var higherIsBetter: Bool { self != .rhr }
        var domain: DomainTheme {
            switch self {
            case .recovery: return .charge
            case .hrv, .sleep: return .rest
            case .rhr: return .stress
            }
        }
        func format(_ v: Double) -> String {
            switch self {
            case .recovery, .sleep: return "\(Int(v.rounded())) %"
            case .hrv:              return "\(Int(v.rounded())) ms"
            case .rhr:              return "\(Int(v.rounded())) bpm"
            }
        }
        /// The outcome's unit (a Charge or Rest change is in points of its 0–100 score).
        var unit: String {
            switch self {
            case .recovery, .sleep: return "%"
            case .hrv:              return "ms"
            case .rhr:              return "bpm"
            }
        }
        /// A change in the outcome, signed, in its own units ("−8 %", "+4 ms").
        func signedDelta(_ d: Double, includeUnit: Bool = true) -> String {
            let sign = d > 0 ? "+" : (d < 0 ? "−" : "")
            let magnitude = abs(d) >= 10 || self != .hrv && self != .rhr
                ? "\(Int(abs(d).rounded()))" : String(format: "%.1f", abs(d))
            return includeUnit ? "\(sign)\(magnitude) \(unit)" : "\(sign)\(magnitude)"
        }
        /// The comparison axis: the fixed 0–100 score scale, or zero to a little above the larger value.
        func axis(_ a: Double, _ b: Double) -> ClosedRange<Double> {
            switch self {
            case .recovery, .sleep: return 0...100
            case .hrv, .rhr:        return 0...max(1, max(a, b) * 1.15)
            }
        }
    }

    // MARK: Published state

    @Published private(set) var loaded = false
    @Published private(set) var ranked: [RankedEffect] = []
    @Published private(set) var doseCards: [DoseCard] = []

    // MARK: Loaded inputs (kept so the outcome segmented control can re-rank cheaply)

    private var behaviours: [String: Set<String>] = [:]
    /// Per behaviour, the days it was logged NO — the only legitimate control group.
    private var controls: [String: Set<String>] = [:]
    private var outcomeByKey: [String: [String: Double]] = [:]
    private var currentOutcome: Outcome = .recovery

    /// The source id dose rows are parked under (mirrors MoodStore's noop-mood isolation).
    static let doseSource = "noop-journal-dose"

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    // MARK: Load

    func load(repo: Repository) async {
        // Journal → behaviour → days (only "yes" answers count as the behaviour occurring).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controlsByBehaviour: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controlsByBehaviour[e.question, default: []].insert(e.day) }
        }

        // Outcome series: imported metricSeries ∪ the DailyMetric column fallback so an
        // account-free (strap-only) user still gets effects — the exact contract InsightsView uses.
        let mergedDays = repo.days
        var byKey: [String: [String: Double]] = [:]
        for key in outcomeKeys {
            let s = await repo.series(key: key, source: "my-whoop")
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                if let v = Self.dailyOutcome(key: key, day: d) { dict[d.day] = v }
            }
            byKey[key] = dict
        }

        // Dose rows per dosed behaviour, under the dedicated dose source, keyed by the
        // behaviour's storage key. A logged "yes" with no dose row reads as dose = 1
        // (back-compatible), so we union the behaviour's logged days at dose 1 with any
        // explicit dose rows (explicit wins).
        var doseByBehaviour: [DosedBehavior: [String: Int]] = [:]
        for behavior in DosedBehavior.allCases {
            let key = Self.doseKey(for: behavior)
            let rows = await repo.series(key: key, source: Self.doseSource)
            var doses: [String: Int] = [:]
            // Back-compat: any logged "yes" day for a matching journal question starts at dose 1.
            for (question, days) in byBehaviour where Self.matches(behavior, question: question) {
                for day in days { doses[day] = max(doses[day] ?? 0, 1) }
            }
            // Explicit dose rows override.
            for row in rows { doses[row.day] = Int(row.value.rounded()) }
            if !doses.isEmpty { doseByBehaviour[behavior] = doses }
        }

        // Build the dose cards from the engine (alcohol first, then caffeine).
        var cards: [DoseCard] = []
        for behavior in DosedBehavior.allCases {
            guard let doses = doseByBehaviour[behavior] else { continue }
            let outcomeName = DoseResponsePriors.defaultOutcome(for: behavior)
            let outcomeKey = Self.outcomeKey(forEngineName: outcomeName)
            let outcomeDays = byKey[outcomeKey] ?? [:]
            guard let response = DoseResponseEngine.estimate(behavior: behavior,
                                                             doseByDay: doses,
                                                             outcomeByDay: outcomeDays) else { continue }
            let latest = outcomeDays.keys.max().flatMap { outcomeDays[$0] }
            cards.append(DoseCard(behavior: behavior, response: response, latestOutcome: latest))
        }

        self.behaviours = byBehaviour
        self.controls = controlsByBehaviour
        self.outcomeByKey = byKey
        self.doseCards = cards
        self.loaded = true
        rankFor(currentOutcome)
    }

    /// Re-rank the mover feed for a (possibly new) outcome selection — cheap, no DB.
    func rankFor(_ outcome: Outcome) {
        currentOutcome = outcome
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = EffectRanker.rank(behaviors: behaviours,
                                   controls: controls,
                                   outcomeByDay: outcomeDays,
                                   outcome: outcome.outcomeName)
    }

    // MARK: Static shaping helpers

    /// The merged DailyMetric column backing an outcome key (strap-only fallback). sleep_performance
    /// has no daily column, so it stays import-only — never seeded here (matches InsightsView).
    private static func dailyOutcome(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }

    /// The metricSeries key a DoseResponsePriors outcome NAME maps to ("Charge"→recovery, "HRV"→hrv).
    static func outcomeKey(forEngineName name: String) -> String {
        switch name {
        case "Charge": return "recovery"
        case "HRV":    return "hrv"
        case "Rest":   return "sleep_performance"
        case "Resting HR": return "rhr"
        default:       return "recovery"
        }
    }

    /// The dose storage key for a behaviour (its raw enum value — the stable, cross-platform key).
    static func doseKey(for behavior: DosedBehavior) -> String { "dose_\(behavior.rawValue)" }

    /// Whether a journal question is the dosed behaviour (so its yes-days back-fill dose = 1).
    static func matches(_ behavior: DosedBehavior, question: String) -> Bool {
        let q = question.lowercased()
        switch behavior {
        case .alcohol:  return q.contains("alcohol") || q.contains("drink")
        case .caffeine: return q.contains("caffeine") || q.contains("coffee")
        }
    }

    // MARK: Dose card view-data

    struct DoseCard: Identifiable {
        let behavior: DosedBehavior
        let response: DoseResponse
        /// The user's most recent outcome value (for the evening damage forecast anchor).
        let latestOutcome: Double?

        var id: String { behavior.rawValue }
        var outcomeName: String { response.outcome }

        var title: String {
            switch behavior {
            case .alcohol:  return String(localized: "Alcohol")
            case .caffeine: return String(localized: "Caffeine")
            }
        }
        var symbol: String {
            switch behavior {
            case .alcohol:  return "wineglass"
            case .caffeine: return "cup.and.saucer.fill"
            }
        }
        /// The unit shown in copy ("drink" / "later step").
        var unitNoun: String {
            switch behavior {
            case .alcohol:  return String(localized: "drink")
            case .caffeine: return String(localized: "later step")
            }
        }
        /// The plural-ish label used in "N of your X days".
        var unitLabel: String {
            switch behavior {
            case .alcohol:  return String(localized: "drink")
            case .caffeine: return String(localized: "late-caffeine")
            }
        }
        var timingProxy: Bool { behavior == .caffeine }

        /// Outcome units suffix for the forecast tiles.
        var outcomeSuffix: String { outcomeName == "HRV" ? " ms" : "%" }
        /// Clamp ceiling for the projected outcome (Charge/Rest are 0–100; HRV uncapped-ish).
        var outcomeCeiling: Double { outcomeName == "HRV" ? 400 : 100 }

        var forecastOverline: String {
            switch behavior {
            case .alcohol:  return String(localized: "Tonight\u{2019}s forecast")
            case .caffeine: return String(localized: "Timing forecast")
            }
        }

        /// The dose choices the evening stepper offers (0/1/2/3 → 0…maxCurveDose).
        var doseChoices: [Int] { Array(0...DoseResponseEngine.maxCurveDose) }
        func doseChoiceLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:  return d >= DoseResponseEngine.maxCurveDose ? "\(d)+" : "\(d)"
            case .caffeine:
                // Timing buckets, not counts.
                switch d {
                case 0: return String(localized: "AM")
                case 1: return String(localized: "Noon")
                case 2: return String(localized: "2pm+")
                default: return String(localized: "Eve")
                }
            }
        }
        /// The whole dose phrase for forecast copy (alcohol counts; caffeine keeps the bare bucket
        /// number). Whole-string keys per variant, never a stitched "+ drinks" suffix.
        func stepLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:
                return d >= DoseResponseEngine.maxCurveDose ? String(localized: "\(d)+ drinks")
                                                            : String(localized: "\(d) drinks")
            case .caffeine:
                return "\(d)"
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func hubPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights Hub") {
    InsightsHubView()
        .environmentObject(hubPreviewRepo())
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}
#endif
