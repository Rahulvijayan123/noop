import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Hours vs Needed (#today-hosted-cards)
//
// The single hours-vs-need metric as its own hostable card for Today. It reads the SAME
// `SleepModel.hoursVsNeeded` metric (latest / typical / series) the Night detail grid reads, so the value,
// the carried-day stamp and the vs-typical line can never diverge between the two surfaces (the parity
// contract).

/// The "Hours vs Needed" card: one kit `MetricTile` from the shared [SleepModel].
struct HoursVsNeededCard: View {
    let model: SleepModel

    var body: some View {
        let need = model.hoursVsNeeded
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Hours vs Needed")
            MetricTile(icon: "clock", iconColor: StrandPalette.restColor, label: "Hours vs Needed",
                       value: need.latest.map { "\(Int($0.rounded()))" }, unit: "%",
                       state: SleepTileCaption.state(need, unit: "%"),
                       trend: need.series.count > 1 ? Array(need.series.suffix(14)) : nil,
                       reservesTrendSlot: true)
        }
    }
}
