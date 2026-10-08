import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Stages (read-only Today host card) (#today-hosted-cards)
//
// The latest night's stages for the Today glance: the SAME night and stage timeline the Sleep tab shows
// (the shared `SleepModel`), drawn by the Sleep tab's own `NightTimelineChart`, with the legend row (tap a
// stage to highlight it) and the first applicable stage caveat as a badge. Read-only: no night stepping,
// no edits; the Sleep tab owns those. A night imported with stage totals only shows its composition bar,
// never a reconstructed timeline.

/// The read-only "Stages" card hosted in Today, rendered from the shared [SleepModel].
struct StagesCard: View {
    let model: SleepModel

    @EnvironmentObject private var repo: Repository
    /// Transient tap-highlight, local to this card.
    @State private var highlighted: SleepStage?

    private static let stageHeight: CGFloat = 104

    var body: some View {
        let night = model.night
        let isStub = model.isStubNight
        let caveats = isStub ? [] : SleepCaveat.applicable(to: night, todayEfficiency: repo.today?.efficiency,
                                                           isOura: repo.activeDeviceIsOura)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages", trailing: SleepFormat.nightDateLine(night.session.endTs))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Group {
                        if model.isPersistedHypnogram {
                            NightTimelineChart(
                                timeline: NightTimeline(onset: night.onsetDate,
                                                        end: Date(timeIntervalSince1970: TimeInterval(night.session.endTs)),
                                                        intervals: model.intervals),
                                highlighted: highlighted,
                                stageHeight: Self.stageHeight)
                        } else if !isStub {
                            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                Spacer(minLength: 0)
                                StageCompositionBar(stages: night.stages, highlighted: highlighted, height: 20)
                                Text("Stage totals only")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Spacer(minLength: 0)
                            }
                        } else {
                            EmptyChartMessage("No stage data recorded for this night.",
                                              height: SleepView.compactChartHeight)
                        }
                    }
                    .frame(height: SleepView.compactChartHeight)
                    if !isStub {
                        StageLegendRow(stages: night.stages, highlighted: $highlighted)
                    }
                    if let first = caveats.first {
                        HStack(spacing: NoopMetrics.space2) {
                            SleepCaveatBadge(caveat: first)
                            if caveats.count > 1 {
                                Text("+\(caveats.count - 1)")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        .onChangeCompat(of: night.session.startTs) { _ in highlighted = nil }
    }
}
