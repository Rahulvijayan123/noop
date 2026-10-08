import SwiftUI
import StrandDesign
import StrandAnalytics

/// Add or edit one timed event. Saving writes a new revision (the earlier ones are kept); Remove writes a
/// retraction. Time can be a moment or a range, exact or approximate; amount and unit are optional.
struct ExposureEventEditorView: View {
    let event: PhysiologyContext.ExposureEvent?
    let onDone: () -> Void

    @State private var draft: ExposureEventDraft
    @State private var working = false
    @State private var failed = false
    @State private var confirmingRemove = false

    init(event: PhysiologyContext.ExposureEvent? = nil, defaultTime: Date = Date(),
         onDone: @escaping () -> Void = {}) {
        self.event = event
        self.onDone = onDone
        _draft = State(initialValue: event.map(ExposureEventDraft.init(event:)) ?? ExposureEventDraft(start: defaultTime))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(PhysiologyContext.ExposureKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    LabeledContent("Name") {
                        TextField("Optional", text: $draft.label)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .eventEditorRow()

                Section {
                    Toggle("Time range", isOn: isRange)
                        .tint(StrandPalette.accent)
                    DatePicker(draft.end == nil ? "Time" : "Start", selection: $draft.start)
                    if draft.end != nil {
                        DatePicker("End", selection: endBinding)
                    }
                    Picker("Time is", selection: $draft.precision) {
                        Text("Exact").tag(PhysiologyContext.TimePrecision.exact)
                        Text("Approximate").tag(PhysiologyContext.TimePrecision.approximate)
                    }
                    .pickerStyle(.segmented)
                }
                .eventEditorRow()

                Section {
                    LabeledContent("Amount") {
                        TextField("Optional", text: $draft.doseText)
                            .multilineTextAlignment(.trailing)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                    LabeledContent("Unit") {
                        TextField("e.g. mg", text: $draft.doseUnit)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    if !messages.isEmpty {
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            ForEach(messages, id: \.self) { message in
                                Text(message)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.statusWarning)
                            }
                        }
                    }
                }
                .eventEditorRow()

                if event != nil {
                    Section {
                        Button("Remove event", role: .destructive) { confirmingRemove = true }
                            .disabled(working)
                    }
                    .eventEditorRow()
                }
            }
            .eventEditorForm()
            .navigationTitle(event == nil ? "Add event" : "Edit event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !draft.problems.isEmpty)
                }
            }
            .confirmationDialog("Remove this event?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    private var isRange: Binding<Bool> {
        Binding(get: { draft.end != nil },
                set: { on in draft.end = on ? draft.start.addingTimeInterval(3600) : nil })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { draft.end ?? draft.start.addingTimeInterval(3600) }, set: { draft.end = $0 })
    }

    private var messages: [String] {
        var out = draft.problems.map { problem -> String in
            switch problem {
            case .endBeforeStart: return String(localized: "The end has to be after the start.")
            case .doseNotANumber: return String(localized: "The amount has to be a number.")
            }
        }
        if failed { out.append(String(localized: "Couldn't save. Try again.")) }
        return out
    }

    private func save() {
        working = true
        failed = false
        let draft = self.draft
        Task {
            let ok = await ExposureEventEditing.save(draft, editing: event)
            working = false
            if ok { onDone() } else { failed = true }
        }
    }

    private func remove() {
        guard let event else { return }
        working = true
        failed = false
        Task {
            let ok = await ExposureEventEditing.remove(event)
            working = false
            if ok { onDone() } else { failed = true }
        }
    }
}

/// Writes editor changes as new revisions, off the main thread, then sends them on a best-effort flush.
@MainActor
enum ExposureEventEditing {
    /// Save `draft` as the next revision of `editing` (or a new event). True when stored or nothing changed.
    static func save(_ draft: ExposureEventDraft, editing: PhysiologyContext.ExposureEvent?) async -> Bool {
        guard let store = await ExposureEventStoreLocator.resolve() else { return false }
        let owner = ExposureJournalBridge.currentOwner()
        let eventId = editing?.eventId ?? ExposureEventIds.fresh()
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                let previous = try store.latest(owner: owner, eventId: eventId)
                if let next = draft.revision(eventId: eventId, previous: previous, recordedAt: Date()) {
                    try store.record(next, owner: owner)
                }
                return true
            } catch {
                NSLog("ExposureEventEditing: save failed: \(error)")
                return false
            }
        }.value
        if ok { Task { await ExposureEventCloudSync.flush() } }
        return ok
    }

    /// Retract `event`. A caffeine intake logged on the caffeine card is removed from the card too.
    static func remove(_ event: PhysiologyContext.ExposureEvent) async -> Bool {
        guard let store = await ExposureEventStoreLocator.resolve() else { return false }
        let owner = ExposureJournalBridge.currentOwner()
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                _ = try store.retract(owner: owner, eventId: event.eventId,
                                      recordedAt: Int(Date().timeIntervalSince1970))
                return true
            } catch {
                NSLog("ExposureEventEditing: remove failed: \(error)")
                return false
            }
        }.value
        if ok {
            if event.kind == .caffeine, let id = UUID(uuidString: event.eventId) {
                CaffeineLogStore.shared.remove(id)
            }
            Task { await ExposureEventCloudSync.flush() }
        }
        return ok
    }
}
