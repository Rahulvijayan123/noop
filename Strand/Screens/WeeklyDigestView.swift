import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Weekly Digest (#208)
//
// A deterministic, offline "week in review". Reads the local DailyMetric history
// from the Repository, pulls each tracked metric into a day→value map, and feeds
// WeeklyDigestEngine (pure, in StrandAnalytics) to produce a Monday-anchored
// summary: per-metric this-week mean + week-over-week delta + vs-baseline, the
// biggest movers, a strain-vs-recovery balance read, and 1–2 plain-English focal
// points. No AI, no network — the engine is fully deterministic and unit-tested.
//
// Surfaces, all sharing `WeeklyDigestContent` so they never drift:
//   • the Trends week summary (`WeeklyDigestContent(compact: true)`), stepped week by week;
//   • `WeeklyDigestView` — the full page one tap below it;
//   • `WeeklyDigestCard` — an embeddable card (no caller today).
//
// Framing is informational and non-clinical, consistent with the app DISCLAIMER.

// MARK: - Shared digest builder (pure glue over the engine)

enum WeeklyDigestSource {

    /// Build the digest for the week containing today's local day from a DailyMetric
    /// history. Extracts each tracked metric into a "yyyy-MM-dd"→value map and hands
    /// it to the pure engine.
    static func digest(from days: [DailyMetric],
                       anchorDay: String,
                       effortDisplayFactor: Double = UnitPrefs.currentEffortDisplayFactor()) -> WeeklyDigest {
        var charge: [String: Double] = [:]
        var effort: [String: Double] = [:]
        var rest: [String: Double] = [:]
        var rhr: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        for d in days {
            if let v = d.recovery { charge[d.day] = v }
            if let v = d.strain   { effort[d.day] = v }
            // Rest = the sleep-performance composite, recomputed on the persisted day.
            if let r = restScore(for: d) { rest[d.day] = r }
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.avgHrv    { hrv[d.day] = v }
        }
        return WeeklyDigestEngine.build(
            byMetric: [.charge: charge, .effort: effort, .rest: rest, .rhr: rhr, .hrv: hrv],
            anchorDay: anchorDay,
            effortDisplayFactor: effortDisplayFactor)
    }

    /// The 0–100 Rest composite for a persisted day, via AnalyticsEngine's display-path
    /// helper (duration-vs-need / efficiency / restorative / consistency). Returns nil
    /// for a day with no in-bed sleep / missing efficiency, so non-sleep days are simply
    /// absent from the Rest series.
    private static func restScore(for d: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: d)
    }
}

// MARK: - Embeddable card

/// The weekly digest as a single card (for Today / Trends). Renders nothing
/// (an empty view) when there's no data this week, so it's safe to always place.
struct WeeklyDigestCard: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
        if digest.isEmpty {
            EmptyView()
        } else {
            // Content owns its own card, so it is not wrapped in another one. The compact flag trims it
            // to the three headline scores and one focal point.
            WeeklyDigestContent(digest: digest, compact: true)
        }
    }
}

// MARK: - Full screen

/// The week in review as a full page, one tap below the Trends week summary: the three scores with their
/// week-over-week change, every focal point, the nightly signals, and the balance read in About.
struct WeeklyDigestView: View {
    @EnvironmentObject var repo: Repository
    /// Any day in the week to show; the engine snaps it to that week's Monday. Today by default.
    var anchorDay: String = Repository.localDayKey(Date())

    var body: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: anchorDay)
        ScreenScaffold(title: "Week in review", dateLine: weeklyDigestRangeLabel(digest),
                       titleDisplay: .navigationBar, isLoading: !repo.loaded) {
            if repo.loaded && digest.isEmpty {
                ComingSoon(what: "No readings this week")
            } else {
                WeeklyDigestContent(digest: digest, compact: false, showsHeader: false)
                AboutDisclosure(paragraphs: aboutParagraphs(digest))
            }
        }
    }

    private func aboutParagraphs(_ digest: WeeklyDigest) -> [String] {
        var out: [String] = []
        if let sd = digest.sleepConsistencySD {
            out.append(String(localized: "Sleep steadiness: Rest varied ±\(String(format: "%.1f", sd)) pts night to night."))
        }
        out.append(digest.balance.sentence)
        out.append(String(localized: "The week in review covers Monday to Sunday. Its Rest is the nightly sleep composite, recomputed for each night."))
        out.append(String(localized: "Informational only, not medical advice."))
        return out
    }
}

// MARK: - Shared content

/// Compact, localized range shared by the standalone digest card and the Trends week navigator.
func weeklyDigestRangeLabel(_ digest: WeeklyDigest) -> String {
    "\(weeklyDigestShortDate(digest.weekStart))–\(weeklyDigestShortDate(digest.weekEnd))"
}

/// "Jun 8" from "2026-06-08", via the engine's own pure parse (no Calendar).
private func weeklyDigestShortDate(_ ymd: String) -> String {
    guard let (_, month, day) = WeeklyDigestEngine.parseYMD(ymd) else { return ymd }
    let months = [String(localized: "Jan"), String(localized: "Feb"), String(localized: "Mar"),
                  String(localized: "Apr"), String(localized: "May"), String(localized: "Jun"),
                  String(localized: "Jul"), String(localized: "Aug"), String(localized: "Sep"),
                  String(localized: "Oct"), String(localized: "Nov"), String(localized: "Dec")]
    let name = (1...12).contains(month) ? months[month - 1] : "\(month)"
    return "\(name) \(day)"
}

/// The week's content, shared by the Trends summary (`compact`), the full page and the shared image.
///
/// - The three headline scores (Charge, Effort, Rest) as value columns, each with its week-over-week
///   change as a signed number in the score's own units (points, never a percent of a percentage).
/// - `compact`: the first focal point under them. Full page: every focal point, then HRV and resting HR.
struct WeeklyDigestContent: View {
    let digest: WeeklyDigest
    var compact: Bool = false
    var showsHeader: Bool = true

    /// The Effort display scale (#268), so the week's Effort matches the Today tile and the Trends chart
    /// instead of being stuck on the stored 0–100. Charge/Rest stay 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// The three headline 0–100 scores.
    private static let scoreOrder: [WeeklyMetric] = [.charge, .effort, .rest]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if showsHeader {
                header
            }
            scoreCard
            if !compact {
                focalCard
                signalsCard
            }
        }
    }

    // MARK: Header (the shared image only)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text("Week in review")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(weeklyDigestRangeLabel(digest))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Text("\(digest.daysWithData)/7 days")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityLabel("\(digest.daysWithData) of 7 days had data this week")
        }
    }

    // MARK: Scores

    @ViewBuilder
    private var scoreCard: some View {
        let summaries = Self.scoreOrder.compactMap { digest.summary($0) }
        if !summaries.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            ForEach(summaries, id: \.metric.rawValue) { scoreColumn($0) }
                        }
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            ForEach(summaries, id: \.metric.rawValue) { scoreColumn($0) }
                        }
                    }
                    if compact, let first = digest.focalPoints.first {
                        Rectangle().fill(StrandPalette.hairline).frame(height: NoopMetrics.hairlineWidth)
                        Text(first)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func scoreColumn(_ s: WeeklyMetricSummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(s.metric.label)
                .strandLabel()
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(numberText(s))
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                if s.thisWeek.n > 0 {
                    Text(scaleText(s))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if hasComparison(s) {
                TrendChip(text: deltaSigned(s), color: chipTone(s))
            } else {
                Text("new")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibility(s, effortScale: effortScale))
    }

    // MARK: Focal points + nightly signals (full page)

    @ViewBuilder
    private var focalCard: some View {
        if !digest.focalPoints.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(Array(digest.focalPoints.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var signalsCard: some View {
        let signals = [WeeklyMetric.hrv, .rhr].compactMap { digest.summary($0) }
        if !signals.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Nightly signals")
                NoopCard {
                    VStack(spacing: NoopMetrics.space3) {
                        ForEach(signals, id: \.metric.rawValue) { metricRow($0) }
                    }
                }
            }
        }
    }

    private func metricRow(_ s: WeeklyMetricSummary) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(s.metric.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space2)
            Text(meanText(s, effortScale: effortScale))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
            if hasComparison(s) {
                TrendChip(text: deltaSigned(s), color: chipTone(s))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibility(s, effortScale: effortScale))
    }

    // MARK: - Formatting

    private func hasComparison(_ s: WeeklyMetricSummary) -> Bool {
        s.weekOverWeek.current.n > 0 && s.weekOverWeek.previous.n > 0
    }

    /// Effort reads to one decimal on the 0–21 scale and as a whole number on 0–100, like Charge and Rest.
    private func effortText(_ v: Double) -> String {
        effortScale == .whoop ? UnitFormatter.effortDisplay(v, scale: effortScale) : "\(Int(v.rounded()))"
    }

    private func numberText(_ s: WeeklyMetricSummary) -> String {
        guard s.thisWeek.n > 0 else { return "—" }
        return s.metric == .effort ? effortText(s.thisWeek.mean) : "\(Int(s.thisWeek.mean.rounded()))"
    }

    /// "of 100" for the genuine 0–100 scores; Effort follows the scale toggle ("of 100"/"of 21").
    private func scaleText(_ s: WeeklyMetricSummary) -> String {
        s.metric == .effort ? String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")
                            : String(localized: "of 100")
    }

    private func meanText(_ s: WeeklyMetricSummary, effortScale: EffortScale) -> String {
        guard s.thisWeek.n > 0 else { return "—" }
        // #463/#268: Effort is STORED 0-100; render it on the user's chosen display scale WITH the
        // denominator ("4.6 / 21", "21.6 / 100") so VoiceOver never speaks a different number than the
        // visible value. Mirrors Android meanText(s, effortScale) byte-for-byte.
        if s.metric == .effort {
            return "\(UnitFormatter.effortDisplay(s.thisWeek.mean, scale: effortScale)) / \(UnitFormatter.effortScaleMax(effortScale))"
        }
        let v = Int(s.thisWeek.mean.rounded())
        return s.metric.unit.isEmpty ? "\(v)" : "\(v) \(s.metric.unit)"
    }

    /// The week-over-week change in the metric's own units, unsigned: points for the 0–100 scores (a
    /// percent change of a percentage would misstate it), the display scale for Effort, ms / bpm for the
    /// nightly signals.
    private func deltaText(_ s: WeeklyMetricSummary) -> String {
        guard hasComparison(s) else { return String(localized: "new") }
        let delta = abs(s.wowDelta)
        if s.metric == .effort {
            return effortText(delta)
        }
        let rounded = Int(delta.rounded())
        return s.metric.unit.isEmpty ? "\(rounded)" : "\(rounded) \(s.metric.unit)"
    }

    /// Whether the change rounds to nothing at the precision it is shown, so it reads as flat.
    private func isFlat(_ s: WeeklyMetricSummary) -> Bool {
        let shown = s.metric == .effort
            ? (effortScale == .whoop ? (UnitFormatter.effortValue(abs(s.wowDelta), scale: effortScale) * 10).rounded() / 10
                                     : abs(s.wowDelta).rounded())
            : abs(s.wowDelta).rounded()
        return shown == 0
    }

    /// The change carrying a +/− so the TrendChip infers its arrow; a change that rounds to zero is "0".
    private func deltaSigned(_ s: WeeklyMetricSummary) -> String {
        guard hasComparison(s) else { return deltaText(s) }
        guard !isFlat(s) else { return "0" }
        let sign = s.wowDelta > 0 ? "+" : (s.wowDelta < 0 ? "−" : "")
        return "\(sign)\(deltaText(s))"
    }

    /// Tone: good moves green, bad moves red, flat/uncomparable grey — folding in each metric's
    /// `higherIsBetter` so a Resting-HR rise reads as a warning. A ROUGH comparison (either side thin,
    /// engine's `isRoughComparison`, the #463 fix) keeps its arrow + number but stays grey regardless of
    /// direction, so the chip can't frame a verdict off 1-2 days. Mirrors the Android
    /// WeeklyDigestCard.chipTone gate byte-for-byte.
    private func chipTone(_ s: WeeklyMetricSummary) -> Color {
        if WeeklyDigestChipStyle.neutralizesTone(s) || isFlat(s) { return StrandPalette.textTertiary }
        switch s.wowGoodness {
        case 1:  return StrandPalette.statusPositive
        case -1: return StrandPalette.statusCritical
        default: return StrandPalette.textTertiary
        }
    }

    private func rowAccessibility(_ s: WeeklyMetricSummary, effortScale: EffortScale) -> String {
        let mean = meanText(s, effortScale: effortScale)
        guard s.weekOverWeek.current.n > 0, s.weekOverWeek.previous.n > 0 else {
            return String(localized: "\(s.metric.label): \(mean) this week, no comparison.")
        }
        // Whole-phrase variants per direction, then a whole-key wrapper per goodness frame, so
        // VoiceOver never hears a stitched half-English fragment.
        let delta = deltaText(s)
        let base: String
        if s.wowDelta > 0 {
            base = String(localized: "\(s.metric.label): \(mean) this week, up \(delta) week over week")
        } else if s.wowDelta < 0 {
            base = String(localized: "\(s.metric.label): \(mean) this week, down \(delta) week over week")
        } else {
            base = String(localized: "\(s.metric.label): \(mean) this week, unchanged \(delta) week over week")
        }
        // A rough comparison drops the verdict framing too, so VoiceOver matches the neutral chip.
        if WeeklyDigestChipStyle.dropsVerdictFrame(s) { return String(localized: "\(base).") }
        switch s.wowGoodness {
        case 1:  return String(localized: "\(base), a good sign.")
        case -1: return String(localized: "\(base), worth a look.")
        default: return String(localized: "\(base).")
        }
    }
}

// MARK: - Rough-comparison chip contract (#463, testable mirror of Android)

/// The display-side gate for a ROUGH week-over-week comparison (either side thin, engine's
/// `WeeklyMetricSummary.isRoughComparison`). Pulled out of the View's private helpers so it can be
/// pinned by a test without exposing the whole View: `chipTone`/`rowAccessibility` above delegate to
/// these, exactly as the Android WeeklyDigestCard chipTone/rowAccessibility gate on the same flag.
enum WeeklyDigestChipStyle {
    /// A rough comparison keeps its arrow + % but the chip stays grey regardless of direction, so it
    /// can't frame a green/rose verdict off 1-2 days (the #463 complaint).
    static func neutralizesTone(_ s: WeeklyMetricSummary) -> Bool { s.isRoughComparison }
    /// A rough comparison also drops the ", a good sign."/", worth a look." VoiceOver frame so the
    /// spoken row matches the neutral chip.
    static func dropsVerdictFrame(_ s: WeeklyMetricSummary) -> Bool { s.isRoughComparison }
}

#if DEBUG
private func previewDigest() -> WeeklyDigest {
    var charge: [String: Double] = [:], effort: [String: Double] = [:]
    var rest: [String: Double] = [:], hrv: [String: Double] = [:], rhr: [String: Double] = [:]
    // This week (Mon 2026-06-08 .. Sun 2026-06-14) trending up; last week lower.
    for (i, day) in (8...14).enumerated() {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 62 + Double(i) * 3
        effort[k] = 70 - Double(i)
        rest[k] = 82 + Double(i % 3)
        hrv[k] = 58 + Double(i)
        rhr[k] = 53 - Double(i % 2)
    }
    for day in 1...7 {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 55; effort[k] = 64; rest[k] = 80; hrv[k] = 52; rhr[k] = 55
    }
    return WeeklyDigestEngine.build(
        byMetric: [.charge: charge, .effort: effort, .rest: rest, .hrv: hrv, .rhr: rhr],
        anchorDay: "2026-06-13")
}

#Preview("Weekly digest – card") {
    WeeklyDigestContent(digest: previewDigest(), compact: true)
        .padding(24)
        .frame(width: 420)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}

#if os(iOS)
#Preview("Weekly digest – card · accessibility text") {
    WeeklyDigestContent(digest: previewDigest(), compact: true)
        .padding(24)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility1)
}
#endif

#Preview("Weekly digest – full") {
    ScrollView {
        WeeklyDigestContent(digest: previewDigest(), compact: false)
            .padding(24)
    }
    .frame(width: 520, height: 680)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
