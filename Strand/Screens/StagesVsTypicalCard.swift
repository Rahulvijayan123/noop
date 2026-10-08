import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Stages vs typical (#today-hosted-cards)
//
// One night's time in each stage against the wearer's own typical range. Hosted by Today (`init(model:)`,
// the latest night, with its section title) and drawn on the Sleep night page (`init(stages:)`, the night
// on screen, under the page's own "Stages" header).
//
// Each row: the stage's time tonight, a bar on the row's own scale with the TYPICAL RANGE (25th–75th
// percentile of the trailing 30 scored nights, `SleepModel.stageTypical`) as a band behind tonight's
// value, and one line naming the range and where tonight sits in it. Below five scored nights there is no
// range to show, and the row says so instead of inventing one.

struct StagesVsTypicalCard: View {
    private let stages: Stages
    private let showsHeader: Bool

    @EnvironmentObject private var repo: Repository

    /// Today's host: the latest night from the shared model, with the card's section title.
    init(model: SleepModel) {
        self.stages = model.night.stages
        self.showsHeader = true
    }

    /// The night page: any night's totals, without a title (the page names the section).
    init(stages: Stages) {
        self.stages = stages
        self.showsHeader = false
    }

    private let order: [SleepStage] = [.deep, .rem, .light, .awake]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if showsHeader { SectionHeader("Stages vs typical") }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    StageCompositionBar(stages: stages)
                    ForEach(order, id: \.self) { stage in
                        row(stage)
                    }
                }
            }
        }
    }

    private func row(_ stage: SleepStage) -> some View {
        let minutes = StageLegendRow.minutes(stage, in: stages)
        let typical = SleepModel.stageTypical(days: repo.days, stage: stage)
        // The row's own scale when there is a range to compare with; the night's total without one, so the
        // bar is then the stage's share of the night rather than four bars at the same length.
        let scale = typical.map { max(1, max(minutes, $0.hi) * 1.15) } ?? max(1, stages.total)
        let color = StrandPalette.sleepStageColor(stage)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(stage.label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("\(StageLegendRow.share(stage, in: stages)) %")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: NoopMetrics.space2)
                Text(SleepFormat.duration(minutes))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            // A bullet bar: the typical range as a band across the full row height, tonight as a slimmer
            // bar on top of it, so both read at once and neither hides the other.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(StrandPalette.surfaceInset)
                    if let typical {
                        let x0 = w * CGFloat(typical.lo / scale), x1 = w * CGFloat(typical.hi / scale)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(StrandPalette.textTertiary.opacity(0.3))
                            .frame(width: max(2, x1 - x0))
                            .offset(x: x0)
                    }
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: max(5, w * CGFloat(minutes / scale)), height: 5)
                }
            }
            .frame(height: 13)
            .accessibilityHidden(true)
            Text(detail(minutes: minutes, typical: typical))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stage.label))
        .accessibilityValue(Text("\(SleepFormat.duration(minutes)), \(detail(minutes: minutes, typical: typical))"))
    }

    private func detail(minutes: Double, typical: (lo: Double, hi: Double, mean: Double)?) -> String {
        guard let typical else { return String(localized: "No typical range yet") }
        let place = minutes > typical.hi ? String(localized: "above your usual")
            : (minutes < typical.lo ? String(localized: "below your usual") : String(localized: "about your usual"))
        return String(localized: "Typical \(SleepFormat.duration(typical.lo))–\(SleepFormat.duration(typical.hi)) · \(place)")
    }
}
