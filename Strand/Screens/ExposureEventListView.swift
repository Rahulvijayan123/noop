import SwiftUI
import StrandDesign
import StrandAnalytics

/// The exposure events recorded for a window (medication, supplement, caffeine, alcohol, meal, heat, travel,
/// symptom, other), with add, edit and remove. Remove is a retraction: the history is kept. Journal answers and
/// imported entries are shown but edited where they came from. The copy only states what was recorded; it never
/// suggests what an event did.
struct ExposureEventListView: View {
    let window: PhysiologyContext.Interval

    @StateObject private var model = ExposureEventListModel()
    @State private var editing: EditorTarget?
    /// The event a context-menu Remove is waiting to confirm.
    @State private var removing: PhysiologyContext.ExposureEvent?

    init(window: PhysiologyContext.Interval) {
        self.window = window
    }

    var body: some View {
        ScreenScaffold(title: "Recorded events", titleDisplay: .navigationBar) {
            NoopListSection(footer: model.loaded && model.events.isEmpty
                            ? "Not recorded means unknown, not that it didn't happen." : nil) {
                if !model.loaded {
                    // The real row layout, redacted, so the card does not grow when the events land.
                    ForEach(0..<2, id: \.self) { index in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        ExposureEventRow(symbol: "circle.dashed", title: "Medication", label: nil,
                                         detail: "Oct 7, 2:05 PM · 200 mg", showsChevron: false)
                    }
                    .loadingPlaceholder(true)
                } else if model.events.isEmpty {
                    Text("Nothing recorded for this time.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
                } else {
                    ForEach(Array(model.events.enumerated()), id: \.element.eventId) { index, event in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        row(event)
                    }
                }
                NoopListDivider(leadingInset: 0)
                Button {
                    editing = EditorTarget(event: nil)
                } label: {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "plus")
                            .font(StrandFont.icon(.row))
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text("Add event")
                            .font(StrandFont.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: window) { await model.load(window: window) }
        .sheet(item: $editing) { target in
            ExposureEventEditorView(event: target.event, defaultTime: defaultTime) {
                editing = nil
                Task { await model.load(window: window) }
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .confirmationDialog("Remove this event?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { event in
            Button("Remove", role: .destructive) {
                Task { await model.remove(event, window: window) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// New events default to now when the window contains it, else to the window's start.
    private var defaultTime: Date {
        let now = Int(Date().timeIntervalSince1970)
        return Date(timeIntervalSince1970: TimeInterval(window.contains(now) || window.end <= window.start
                                                            ? now : window.start))
    }

    @ViewBuilder
    private func row(_ event: PhysiologyContext.ExposureEvent) -> some View {
        let editable = ExposureEventPresentation.isEditable(event)
        let content = ExposureEventRow(symbol: ExposureEventPresentation.symbol(event.kind),
                                       title: event.kind.title,
                                       label: ExposureEventPresentation.label(event),
                                       detail: ExposureEventPresentation.detail(event),
                                       showsChevron: editable)
        if editable {
            Button { editing = EditorTarget(event: event) } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
                .contextMenu {
                    Button("Edit") { editing = EditorTarget(event: event) }
                    Button("Remove", role: .destructive) { removing = event }
                }
        } else {
            content
        }
    }

    struct EditorTarget: Identifiable {
        let id = UUID()
        let event: PhysiologyContext.ExposureEvent?
    }
}

/// One recorded event: the kind's icon, the kind, the person's own label, and what was recorded about its
/// time and amount (several short facts, so the detail may wrap). Laid out like `NoopListRow`.
private struct ExposureEventRow: View {
    let symbol: String
    let title: String
    let label: String?
    let detail: String
    let showsChevron: Bool

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(verbatim: title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let label {
                    Text(verbatim: label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Loads the window's current events from the on-device store (off the main thread) and retracts on remove.
@MainActor
final class ExposureEventListModel: ObservableObject {
    @Published private(set) var events: [PhysiologyContext.ExposureEvent] = []
    @Published private(set) var loaded = false

    func load(window: PhysiologyContext.Interval) async {
        guard let store = await ExposureEventStoreLocator.resolve() else { loaded = true; return }
        let owner = ExposureJournalBridge.currentOwner()
        let rows = await Task.detached(priority: .userInitiated) {
            (try? store.current(owner: owner, from: window.start, to: window.end)) ?? []
        }.value
        events = rows
        loaded = true
    }

    func remove(_ event: PhysiologyContext.ExposureEvent, window: PhysiologyContext.Interval) async {
        _ = await ExposureEventEditing.remove(event)
        await load(window: window)
    }
}

/// Wording for an event row. States what was recorded and how well its time is known; nothing more.
enum ExposureEventPresentation {
    /// Journal answers are changed in the journal, imported entries in the app they came from.
    static func isEditable(_ e: PhysiologyContext.ExposureEvent) -> Bool {
        e.source == .userEntered
    }

    /// The row icon for a kind.
    static func symbol(_ kind: PhysiologyContext.ExposureKind) -> String {
        switch kind {
        case .medication: return "pills"
        case .supplement: return "leaf"
        case .caffeine: return "cup.and.saucer"
        case .alcohol: return "wineglass"
        case .meal: return "fork.knife"
        case .heat: return "thermometer.sun"
        case .travel: return "airplane"
        case .symptom: return "bandage"
        case .other: return "circle.dashed"
        }
    }

    /// The label when it says more than the kind does.
    static func label(_ e: PhysiologyContext.ExposureEvent) -> String? {
        let l = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.lowercased() != e.kind.rawValue, l.lowercased() != e.kind.title.lowercased() else {
            return nil
        }
        return l
    }

    static func detail(_ e: PhysiologyContext.ExposureEvent) -> String {
        var parts = [time(e)]
        if let amount = e.doseAmount {
            parts.append([ExposureEventDraft.format(amount), e.doseUnit].compactMap { $0 }.joined(separator: " "))
        }
        switch e.confirmation {
        case .denied: parts.append(String(localized: "Answered no"))
        case .candidate: parts.append(String(localized: "Not confirmed"))
        case .confirmed, .retracted: break
        }
        switch e.source {
        case .journalDayAnswer: parts.append(String(localized: "Journal"))
        case .imported: parts.append(String(localized: "Imported"))
        case .userEntered, .inferredCandidate: break
        }
        if e.revisionCount > 1 { parts.append(String(localized: "Edited")) }
        return parts.joined(separator: " · ")
    }

    static func time(_ e: PhysiologyContext.ExposureEvent) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(e.occurred.start))
        let end = Date(timeIntervalSince1970: TimeInterval(e.occurred.end))
        switch e.timePrecision {
        case .dayOnly:
            let day = start.formatted(date: .abbreviated, time: .omitted)
            return String(localized: "\(day), time not recorded")
        case .exact where e.occurred.duration <= 1:
            return start.formatted(date: .abbreviated, time: .shortened)
        case .approximate where e.occurred.duration == 2 * ExposureEventDraft.approximateHalfWidthS:
            let mid = start.addingTimeInterval(TimeInterval(ExposureEventDraft.approximateHalfWidthS))
            let text = mid.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Around \(text)")
        default:
            let from = start.formatted(date: .abbreviated, time: .shortened)
            let to = end.formatted(date: .omitted, time: .shortened)
            return e.timePrecision == .approximate ? String(localized: "Roughly \(from) – \(to)")
                                                   : "\(from) – \(to)"
        }
    }
}
