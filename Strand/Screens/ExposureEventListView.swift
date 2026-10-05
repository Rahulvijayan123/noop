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

    init(window: PhysiologyContext.Interval) {
        self.window = window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recorded events")
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    if model.events.isEmpty {
                        Text(model.loaded ? "Nothing recorded for this time. Not recorded means unknown, not that it didn't happen."
                                          : "Loading…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(model.events, id: \.eventId) { event in
                            row(event)
                            if event.eventId != model.events.last?.eventId {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    Button {
                        editing = EditorTarget(event: nil)
                    } label: {
                        Label("Add event", systemImage: "plus")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
        .task(id: window) { await model.load(window: window) }
        .sheet(item: $editing) { target in
            ExposureEventEditorView(event: target.event, defaultTime: defaultTime) {
                editing = nil
                Task { await model.load(window: window) }
            }
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
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let label = ExposureEventPresentation.label(event) {
                    Text(label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(ExposureEventPresentation.detail(event))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if editable {
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        if editable {
            Button { editing = EditorTarget(event: event) } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
                .contextMenu {
                    Button("Edit") { editing = EditorTarget(event: event) }
                    Button("Remove", role: .destructive) {
                        Task { await model.remove(event, window: window) }
                    }
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
