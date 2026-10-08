import SwiftUI
import StrandDesign

// MARK: - NoopLimitationsView — "what NOOP can (and can't) read off each strap"
//
// The iOS/macOS twin of Android's NoopLimitationsScreen: a plain tri-state capability grid listing every
// metric NOOP surfaces and whether it comes live off a WHOOP 4.0 vs a 5.0/MG. Marks mirror the
// decoder/analytics truth (Interpreter / AnalyticsEngine / HistoricalStreams): full = read live; partial =
// an on-device estimate or an experimental / firmware-gated read; none = not off the strap (SpO₂ % is
// import-only on both; blood pressure has no path). A legend carries the meaning in place of per-row prose.
// Rendered through the shared ScreenScaffold like every other destination — reached from the iOS More tab
// (Data group) and the macOS sidebar (Data & App); navigation chrome (back / tab bar) handles dismissal.

struct NoopLimitationsView: View {

    /// Tri-state support for a metric on a given strap — honest, never overstated.
    private enum LimitState {
        case full, partial, none

        /// SF Symbol glyph shown in the strap column.
        var glyph: String {
            switch self {
            case .full:    return "checkmark"
            case .partial: return "minus"
            case .none:    return "xmark"
            }
        }

        var tint: Color {
            switch self {
            case .full:    return StrandPalette.statusPositive
            case .partial: return StrandPalette.statusWarning
            case .none:    return StrandPalette.textTertiary
            }
        }

        /// Spoken label for the row's accessibility description.
        var spoken: String {
            switch self {
            case .full:    return String(localized: "yes")
            case .partial: return String(localized: "partly")
            case .none:    return String(localized: "no")
            }
        }
    }

    /// One row: a metric, and how it reads on a 4.0 vs a 5.0/MG. No note — the legend carries the meaning.
    private struct LimitRow: Identifiable {
        let feature: LocalizedStringKey
        let spokenFeature: String
        let whoop4: LimitState
        let whoop5: LimitState
        var id: String { spokenFeature }
    }

    private let rows: [LimitRow] = [
        LimitRow(feature: "Live heart rate", spokenFeature: "Live heart rate", whoop4: .full, whoop5: .full),
        LimitRow(feature: "HRV (rMSSD)", spokenFeature: "HRV", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Sleep staging", spokenFeature: "Sleep staging", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Recovery & strain", spokenFeature: "Recovery and strain", whoop4: .full, whoop5: .full),
        // `.partial` on BOTH generations: the displayed respiratory rate is always
        // `SleepStager.respRateFromRR` — an on-device RSA estimate off the R-R stream, which is what
        // `.partial` means — computed with NO family branch (`AnalyticsEngine`'s `respRateDaily`). The
        // 5.0/MG v18 wire carries no respiratory channel at all (`Whoop5HistoricalTests…` pins
        // `resp_rate_raw` nil); the 4.0 v24 layout DOES carry `resp_rate_raw`, but it is a raw ADC stored
        // unconverted (schema: "resp rate computed server-side", `HistoricalStreams` keeps it as a raw
        // `RespSample`) and never becomes the shown value. Neither is "read live off the strap" (`.full`)
        // — which is also why an over-counted-R-R 4.0 night (#1331) blanks it.
        LimitRow(feature: "Respiratory rate", spokenFeature: "Respiratory rate", whoop4: .partial, whoop5: .partial),
        LimitRow(feature: "Stress (on-device)", spokenFeature: "Stress", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Workout detection", spokenFeature: "Workout detection", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Skin temperature", spokenFeature: "Skin temperature", whoop4: .partial, whoop5: .full),
        LimitRow(feature: "Steps", spokenFeature: "Steps", whoop4: .partial, whoop5: .full),
        LimitRow(feature: "Blood oxygen (SpO₂ %)", spokenFeature: "Blood oxygen", whoop4: .none, whoop5: .none),
        LimitRow(feature: "ECG", spokenFeature: "ECG", whoop4: .none, whoop5: .partial),
        LimitRow(feature: "Blood pressure", spokenFeature: "Blood pressure", whoop4: .none, whoop5: .none),
    ]

    var body: some View {
        ScreenScaffold(title: "Nara limitations", titleDisplay: .navigationBar) {
            tableCard
            legend
        }
    }

    // MARK: - Table

    private var tableCard: some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Column header.
                HStack {
                    Text("Reads").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("4.0").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 60)
                    Text("5.0/MG").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 60)
                }
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.vertical, NoopMetrics.space3)
                ForEach(rows) { row in
                    NoopListDivider()
                    HStack {
                        Text(row.feature).font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        supportCell(row.whoop4)
                        supportCell(row.whoop5)
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(a11yLabel(row))
                }
            }
        }
    }

    /// What the three marks mean, as one quiet block under the table.
    private var legend: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            legendRow(.full, "Read live off the strap")
            legendRow(.partial, "On-device estimate, or experimental / firmware-gated")
            legendRow(.none, "Not from the strap. SpO₂ can be filled by importing a WHOOP or Health export.")
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    private func legendRow(_ state: LimitState, _ label: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: state.glyph)
                .font(StrandFont.icon(.inline).weight(.semibold))
                .foregroundStyle(state.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label).font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func supportCell(_ state: LimitState) -> some View {
        Image(systemName: state.glyph)
            .font(StrandFont.icon(.row).weight(.semibold))
            .foregroundStyle(state.tint)
            .frame(width: 60)
            .accessibilityHidden(true)
    }

    /// VoiceOver line for one row, assembled at runtime from already-localized parts. A plain String (not a
    /// LocalizedStringKey), so it carries no catalog key of its own.
    private func a11yLabel(_ row: LimitRow) -> String {
        "\(row.spokenFeature): WHOOP 4.0 \(row.whoop4.spoken), 5.0/MG \(row.whoop5.spoken)"
    }
}
