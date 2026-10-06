import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Sleep-debt ledger (#today-hosted-cards)
//
// The Sleep tab's "Sleep-debt ledger" card, extracted into a standalone view so it can ALSO be hosted in
// the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so the
// recency-weighted estimate can never diverge between the two surfaces (the parity contract). The
// card body + its `debtDeltaBars` strip and the debt-only formatting helpers (`debtHeadline` /
// `debtTag` / `debtRead` / `debtBalanceColor` / `debtSigned`) are a verbatim lift of the former
// `SleepView.sleepDebtLedger` (and the helpers only it used); the nap-credited ledger is computed once in
// `SleepModel.build` (the shared builder) and read here — it is NOT recomputed.

/// The "Sleep-debt ledger" card. A recency-weighted estimate across the recent fortnight — the
/// current debt headline, a plain-English read, and a diverging raw per-night delta bar —
/// rendered from the shared [SleepModel]'s `sleepDebtLedger`. (#242)
struct SleepDebtLedgerCard: View {
    let model: SleepModel

    var body: some View {
        let ledger = model.sleepDebtLedger
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep-debt ledger", overline: "Last 14 nights")
            NoopCard(tint: StrandPalette.restColor) {
                if ledger.nightCount == 0 {
                    Text("No nights with sleep data yet. Your ledger fills in as you wear the strap to bed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        // Headline: net balance (count-up on appear) + the short tag (DEBT / SURPLUS / ON
                        // TARGET). The number ticks from the accumulated magnitude via the same formatter.
                        HStack(alignment: .firstTextBaseline) {
                            CountUpText(
                                value: ledger.magnitudeMin,
                                format: { debtHeadline(forMagnitudeMin: $0, ledger: ledger) },
                                font: StrandFont.number(26),
                                color: debtBalanceColor(ledger)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            Spacer(minLength: NoopMetrics.space2)
                            Text(debtTag(ledger))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(debtBalanceColor(ledger))
                        }
                        Text(debtRead(ledger))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Raw per-night delta bars (above/below base need), intentionally separate
                        // from the recurrence's current debt estimate.
                        debtDeltaBars(ledger)
                        Divider().overlay(StrandPalette.hairline)
                        ChartFooter([
                            ("Balance", debtSigned(ledger.balanceMin)),
                            ("Per-night need", durationText(ledger.needMin)),
                            ("Nights", "\(ledger.nightCount)"),
                        ])
                    }
                }
            }
        }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let weekdayFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEEEE"
        return f
    }()
    private static let dayNumberFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d"
        return f
    }()

    /// One column per night: its surplus/shortfall in minutes at the end of its bar, and its weekday and
    /// date underneath. Bars grow up from the centre line for a surplus and down for a shortfall.
    @ViewBuilder
    private func debtDeltaBars(_ ledger: SleepDebtLedger) -> some View {
        let nights = ledger.nights
        let scale = max(nights.map { abs($0.deltaMin) }.max() ?? 1, 1)
        let half: CGFloat = 46
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(nights.enumerated()), id: \.offset) { _, n in
                let surplus = n.deltaMin >= 0
                let h = max(3, CGFloat(abs(n.deltaMin) / scale) * (half - 14))
                let date = Self.dayParser.date(from: n.day)
                VStack(spacing: 6) {
                    ZStack(alignment: .top) {
                        Rectangle().fill(StrandPalette.hairline).frame(height: 1).offset(y: half)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(surplus ? StrandPalette.accent : StrandPalette.metricRose)
                            .frame(height: h)
                            .offset(y: surplus ? half - h : half)
                        Text(debtSigned(n.deltaMin))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(surplus ? StrandPalette.accent : StrandPalette.metricRose)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .offset(y: surplus ? half - h - 15 : half + h + 2)
                    }
                    .frame(height: half * 2 + 4, alignment: .top)
                    VStack(spacing: 0) {
                        Text(date.map { Self.weekdayFormat.string(from: $0) } ?? "")
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                        Text(date.map { Self.dayNumberFormat.string(from: $0) } ?? "")
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-night sleep balance: \(ledger.nightCount) nights, net \(debtSigned(ledger.balanceMin))")
    }

    // MARK: - Sleep-debt ledger formatting (verbatim lift of the ledger-only SleepView helpers)


    /// The same headline formatter, but for an arbitrary (interpolated) magnitude so `CountUpText` can
    /// render a coherent string on every frame as the number ticks up. The on-target deadband check
    /// uses the LIVE magnitude `m` so the headline crosses from "On target" to "≈…" mid-count exactly
    /// once, matching the final reading. Final-value identical to `debtHeadline(_:)`.
    private func debtHeadline(forMagnitudeMin m: Double, ledger: SleepDebtLedger) -> String {
        if m < SleepDebt.onTargetBandMin { return String(localized: "On target") }
        return "≈\(durationText(m))"
    }

    /// Short tag under/beside the headline: DEBT / ON TARGET.
    private func debtTag(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return String(localized: "balanced") }
        return ledger.isDebt ? String(localized: "sleep debt") : String(localized: "balanced")
    }

    /// One factual line under the headline.
    private func debtRead(_ ledger: SleepDebtLedger) -> String {
        let need = durationText(ledger.needMin)
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return String(localized: "Meeting your \(need) need.")
        }
        return String(localized: "\(durationText(ledger.magnitudeMin)) behind your \(need) need.")
    }

    /// Color the balance by size: balanced → positive green, modest debt → warning,
    /// heavier debt → critical.
    private func debtBalanceColor(_ ledger: SleepDebtLedger) -> Color {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return StrandPalette.statusPositive
        }
        // A debt: amber up to ~3 h accumulated, red beyond.
        return ledger.magnitudeMin < 180 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    private func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return String(localized: "0m") }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`). Kept local to the card so it
    /// renders identically whether hosted in Today or shown in the Sleep tab.
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}
