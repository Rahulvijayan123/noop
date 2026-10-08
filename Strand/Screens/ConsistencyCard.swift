import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Consistency (#today-hosted-cards)
//
// The single sleep-consistency metric as its own hostable card for Today. It reads the SAME
// `SleepModel.consistency` metric (the bedtime-onset-spread score that also honours the imported
// consistency figure, byte-identical with Android's `consistencySeries`) the Night detail grid reads, so
// the two surfaces can never diverge (the parity contract).

/// The "Consistency" card: one kit `MetricTile` from the shared [SleepModel].
struct ConsistencyCard: View {
    let model: SleepModel

    var body: some View {
        let cons = model.consistency
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Consistency")
            MetricTile(icon: "calendar", iconColor: StrandPalette.restColor, label: "Consistency",
                       value: cons.latest.map { "\(Int($0.rounded()))" }, unit: "%",
                       state: SleepTileCaption.state(cons, unit: "%"),
                       trend: cons.series.count > 1 ? Array(cons.series.suffix(14)) : nil,
                       reservesTrendSlot: true)
        }
    }
}
