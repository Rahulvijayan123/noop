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
        ScreenScaffold(title: LocalizedStringKey(title), dateLine: subtitle.isEmpty ? nil : subtitle,
                       titleDisplay: .navigationBar, lazy: true) {
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
        SegmentedPillControl([Tab.stretches, .changes], selection: $tab, fillsAvailableWidth: true) { tab in
            switch tab {
            case .stretches: return String(localized: "Stretches")
            case .changes: return String(localized: "Position changes")
            }
        }
    }

    private func emptyLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Stretches

    @ViewBuilder
    private var stretchesList: some View {
        let layout = DayStretchLayout(episodes: episodes, recentCount: 0)
        if layout.earlier.isEmpty {
            emptyLine("This kind of activity only came in moments shorter than a minute.")
        } else {
            ForEach(layout.earlier, id: \.part) { group in
                NoopListSection("\(group.part.title) · \(StretchFormat.count(group.stretches.count))") {
                    ForEach(Array(group.stretches.enumerated()), id: \.element.id) { index, ep in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
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
            emptyLine(family == nil ? "None were flagged on this day." : "None were flagged around these stretches.")
        } else {
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, event in
                        if i > 0 { NoopListDivider() }
                        Button {
                            let at = Date(timeIntervalSince1970: TimeInterval(event.ts))
                            zoom(at.addingTimeInterval(-180)...at.addingTimeInterval(180))
                        } label: {
                            NoopListRow(icon: nil, title: "\(event.kind.displayName)",
                                        subtitle: StretchFormat.clock(Date(timeIntervalSince1970: TimeInterval(event.ts)), seconds: true),
                                        value: "\(Int((event.probability * 100).rounded())) %")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this moment on the heart rate graph")
                    }
                }
            }
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
