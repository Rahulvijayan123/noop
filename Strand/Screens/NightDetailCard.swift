import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Night detail (#today-hosted-cards)
//
// The grid of sleep metrics Today hosts, rendered from the SAME `SleepModel` the Sleep tab builds, so the
// latest value, the carried-day stamp and the vs-typical line can never diverge between the two surfaces
// (the parity contract). Each tile is a kit `MetricTile`: the value in the primary text colour with its
// unit, one state line, and the recent trend as a sparkline in the metric's colour.

/// The "Night detail" card: Rest, Sleep debt, Efficiency, Consistency, Hours vs needed, Restorative and
/// Respiratory, rendered from the shared [SleepModel].
struct NightDetailCard: View {
    let model: SleepModel
    /// Leaves out the tiles a host already shows elsewhere (Rest, Hours vs needed, Sleep debt). Today
    /// keeps the full grid.
    var omitsRepeatedTiles = false

    private let columns = [GridItem(.flexible(), spacing: NoopMetrics.gap),
                           GridItem(.flexible(), spacing: NoopMetrics.gap)]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail")
            LazyVGrid(columns: columns, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(tiles, id: \.label) { t in
                    MetricTile(icon: t.icon, iconColor: t.color, label: LocalizedStringKey(t.label),
                               value: t.value, unit: t.unit, state: t.state, stateTone: t.tone,
                               trend: t.trend, reservesTrendSlot: true)
                }
            }
        }
    }

    private struct Tile {
        let label: String
        let icon: String
        let color: Color
        let value: String?
        let unit: String?
        let state: String?
        var tone: StrandTone = .neutral
        let trend: [Double]?
    }

    private var tiles: [Tile] {
        var out: [Tile] = []
        let perf = model.performance, eff = model.efficiency, cons = model.consistency
        let need = model.hoursVsNeeded, rest = model.restorative, resp = model.respiratory
        let debt = model.sleepDebt
        if !omitsRepeatedTiles {
            out.append(Tile(label: "Rest", icon: "moon.stars", color: StrandPalette.restColor,
                            value: whole(perf.latest), unit: nil,
                            state: SleepTileCaption.state(perf, unit: "%"), trend: spark(perf.series)))
            out.append(Tile(label: "Sleep Debt", icon: "hourglass", color: StrandPalette.restColor,
                            value: debt.latest.map { SleepFormat.duration($0) }, unit: nil,
                            state: debt.latest == nil ? nil : nightDetailDebtCaption(debt.latest),
                            tone: nightDetailDebtTone(debt.latest), trend: spark(debt.series)))
        }
        out.append(Tile(label: "Efficiency", icon: "bed.double", color: StrandPalette.restColor,
                        value: whole(eff.latest), unit: "%",
                        state: SleepTileCaption.state(eff, unit: "%"), trend: spark(eff.series)))
        out.append(Tile(label: "Consistency", icon: "calendar", color: StrandPalette.restColor,
                        value: whole(cons.latest), unit: "%",
                        state: SleepTileCaption.state(cons, unit: "%"), trend: spark(cons.series)))
        if !omitsRepeatedTiles {
            out.append(Tile(label: "Hours vs Needed", icon: "clock", color: StrandPalette.restColor,
                            value: whole(need.latest), unit: "%",
                            state: SleepTileCaption.state(need, unit: "%"), trend: spark(need.series)))
        }
        out.append(Tile(label: "Restorative", icon: "sparkles", color: StrandPalette.sleepREM,
                        value: whole(rest.latest), unit: "%",
                        state: SleepTileCaption.state(rest, unit: "%"), trend: spark(rest.series)))
        out.append(Tile(label: "Respiratory", icon: "lungs", color: StrandPalette.metricPurple,
                        value: resp.latest.map { String(format: "%.1f", $0) }, unit: "rpm",
                        state: SleepTileCaption.state(resp, unit: "rpm", decimals: 1), trend: spark(resp.series)))
        return out
    }

    private func whole(_ v: Double?) -> String? { v.map { "\(Int($0.rounded()))" } }

    /// The last 14 values for the sparkline; nil below two so a tile never draws a one-point line.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(14))
        return tail.count > 1 ? tail : nil
    }
}

func nightDetailDebtCaption(_ debt: Double?) -> String {
    guard let debt else { return String(localized: "vs need") }
    return debt < SleepDebt.onTargetBandMin ? String(localized: "On target") : String(localized: "Below need")
}

func nightDetailDebtColor(_ debt: Double?) -> Color {
    guard let debt else { return StrandPalette.textPrimary }
    switch debt {
    case ..<SleepDebt.onTargetBandMin: return StrandPalette.statusPositive
    case ..<60: return StrandPalette.statusWarning
    default: return StrandPalette.statusCritical
    }
}

/// The state tone for a sleep-debt value: the same thresholds as `nightDetailDebtColor`, for a kit tile's
/// state word (the word carries the meaning; the tone reinforces it).
func nightDetailDebtTone(_ debt: Double?) -> StrandTone {
    guard let debt else { return .neutral }
    switch debt {
    case ..<SleepDebt.onTargetBandMin: return .positive
    case ..<60: return .warning
    default: return .critical
    }
}
