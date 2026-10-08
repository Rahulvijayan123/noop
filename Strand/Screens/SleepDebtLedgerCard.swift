import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Sleep-debt ledger (#today-hosted-cards)
//
// The sleep-debt card Today hosts, rendered from the SAME `SleepModel.sleepDebtLedger` the Sleep tab's
// debt tile reads (the nap-credited, recency-weighted estimate against the normative need, #242), so the
// two can never disagree (the parity contract). The ledger is computed once in `SleepModel.build` and only
// read here.
//
// The card: the current estimate with its state word, then each of the last 14 nights as a bar above or
// below the need (zero = the need met), on an hours axis, so a 20-minute and a two-hour shortfall no
// longer look alike.

/// The "Sleep debt" card from the shared [SleepModel]'s `sleepDebtLedger`. (#242)
struct SleepDebtLedgerCard: View {
    let model: SleepModel

    private static let nights = 14

    var body: some View {
        let ledger = model.sleepDebtLedger
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep debt", trailing: String(localized: "Last 14 nights"))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Text(ledger.nightCount == 0 ? "—" : headline(ledger))
                            .font(StrandFont.number(28))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: NoopMetrics.space2)
                        if ledger.nightCount > 0 {
                            StatePill(isBalanced(ledger) ? LocalizedStringKey("On target") : LocalizedStringKey("Below need"),
                                      tone: tone(ledger), showsDot: false)
                        }
                    }
                    Text(String(localized: "Need \(SleepFormat.duration(ledger.needMin)) a night"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    DivergingBarChart(
                        points: ledger.nights.compactMap { DailyPoint(key: $0.day, value: $0.deltaMin) },
                        positive: StrandPalette.restColor, negative: StrandPalette.metricRose,
                        positiveLabel: String(localized: "Above need"), negativeLabel: String(localized: "Below need"),
                        state: ledger.nightCount == 0 ? .empty(String(localized: "No nights with sleep data yet.")) : .ready,
                        window: AsleepNightsChart.window(nights: Self.nights),
                        xStyle: .dayOfMonth,
                        y: ChartValueAxis(unit: "h", domain: .symmetric(minMagnitude: 60),
                                          stepCandidates: [30, 60, 120, 180, 240],
                                          format: ChartValueAxis.hoursFromMinutes),
                        selection: .constant(nil),
                        height: NoopMetrics.chartHeightSecondary,
                        accessibilityTitle: String(localized: "Sleep balance per night"))
                        .naraChartScrubDisabled()
                }
            }
        }
    }

    // MARK: - Formatting

    private func isBalanced(_ ledger: SleepDebtLedger) -> Bool {
        ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt
    }

    /// "≈1 h 31 m" for a debt (the estimate is recency-weighted, so it is approximate); "0 m" when balanced.
    private func headline(_ ledger: SleepDebtLedger) -> String {
        if isBalanced(ledger) { return SleepFormat.duration(0) }
        return "≈\(SleepFormat.duration(ledger.magnitudeMin))"
    }

    /// Balanced → positive; a debt up to about three hours → warning; heavier → critical.
    private func tone(_ ledger: SleepDebtLedger) -> StrandTone {
        if isBalanced(ledger) { return .positive }
        return ledger.magnitudeMin < 180 ? .warning : .critical
    }
}
