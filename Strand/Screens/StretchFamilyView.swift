import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - One kind of activity, up close
//
// Opened from a box on the Heart rate page ("Sitting", "Asleep or lying down", "Off wrist"…). Lists that kind's
// stretches by part of the day, and the position changes the decoder flagged around them. Each stretch opens in
// the same sheet the page uses, where it can be judged.

struct StretchFamilyView: View {
    enum Scope: Hashable {
        case family(ActivityFamily)
        /// Every position change of the day, with no stretches.
        case positionChanges
    }

    private enum Tab: Hashable { case stretches, changes }

    let scope: Scope
    @ObservedObject var timeline: DayTimelineModel
    /// Show a span on the heart-rate graph, which sits on the page this one was opened from.
    let onZoom: (ClosedRange<Date>) -> Void

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .stretches
    @State private var openStretch: StretchSheetInput?

    private var family: ActivityFamily? {
        if case .family(let f) = scope { return f }
        return nil
    }

    private var episodes: [ActivityEpisode] {
        let all = timeline.activityContext.map { ActivityContextEpisodes.build($0.runs) } ?? []
        guard let family else { return [] }
        return all.filter { ActivityFamily.of($0.label) == family }
    }

    private var changes: [ActivityTransitionEvent] {
        guard let events = timeline.activityContext?.events else { return [] }
        return family == nil ? PositionChanges.all(events) : PositionChanges.near(episodes, in: events)
    }

    private var total: FamilyTotal? {
        guard let family, let doc = timeline.activityContext else { return nil }
        let all = ActivityContextEpisodes.build(doc.runs)
        return DayStretchTotals.familyTotals(doc, episodes: all).first { $0.family == family }
    }

    private var title: String {
        family?.title ?? String(localized: "Position changes")
    }

    private var subtitle: String {
        guard family != nil else { return String(localized: "\(changes.count) flagged today") }
        guard let total else { return "" }
        let time = StretchFormat.duration(total.seconds)
        return total.stretches == 0 ? time : "\(time) · \(StretchFormat.count(total.stretches))"
    }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(title), subtitle: LocalizedStringKey(subtitle), lazy: true) {
            if family != nil { picker }
            if family == nil || tab == .changes {
                changesList
            } else {
                stretchesList
            }
        }
        .sheet(item: $openStretch) { input in
            StretchDetailSheet(input: input, deviceId: repo.deviceId) { range in zoom(range) }
                .environmentObject(repo)
        }
    }

    private var picker: some View {
        SegmentedPillControl([Tab.stretches, .changes], selection: $tab) { tab in
            switch tab {
            case .stretches: return String(localized: "Stretches")
            case .changes: return String(localized: "Position changes")
            }
        }
    }

    // MARK: Stretches

    @ViewBuilder
    private var stretchesList: some View {
        let layout = DayStretchLayout(episodes: episodes, recentCount: 0)
        if layout.earlier.isEmpty {
            DataPendingNote(title: "No stretches this long",
                            message: "This kind of activity only came in moments shorter than a minute.",
                            symbol: "hourglass")
        } else {
            ForEach(layout.earlier, id: \.part) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(group.part.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(StretchFormat.count(group.stretches.count))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, NoopMetrics.space1)
                    ForEach(group.stretches) { ep in
                        StretchRow(episode: ep,
                                   verdict: feedback.feedback(kind: .activityContext, start: ep.start, end: ep.end)) {
                            openStretch = StretchSheetInput(target: .activity(ep), document: timeline.activityContext,
                                                            segments: timeline.dayStates)
                        }
                    }
                }
            }
        }
    }

    // MARK: Position changes

    @ViewBuilder
    private var changesList: some View {
        let shown = changes
        if shown.isEmpty {
            DataPendingNote(title: "No position changes",
                            message: family == nil ? "None were flagged on this day."
                                                   : "None were flagged around these stretches.",
                            symbol: "arrow.up.arrow.down")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, event in
                    Button {
                        let at = Date(timeIntervalSince1970: TimeInterval(event.ts))
                        zoom(at.addingTimeInterval(-180)...at.addingTimeInterval(180))
                    } label: {
                        HStack(spacing: 8) {
                            Text(event.kind.displayName)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 8)
                            Text(StretchFormat.clock(Date(timeIntervalSince1970: TimeInterval(event.ts)), seconds: true))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .monospacedDigit()
                            Text("\(Int((event.probability * 100).rounded()))%")
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                            Image(systemName: "magnifyingglass")
                                .font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this moment on the heart rate graph")
                    if i < shown.count - 1 { Divider().opacity(0.4) }
                }
            }
            .padding(.horizontal, NoopMetrics.space3)
            .background(NoopPanelSurface(cornerRadius: 16))
        }
    }

    // MARK: Showing a span on the graph

    /// The graph is on the page this one was opened from, so show the span there and go back to it.
    private func zoom(_ range: ClosedRange<Date>) {
        onZoom(range)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            dismiss()
        }
    }
}
