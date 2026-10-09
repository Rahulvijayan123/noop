import SwiftUI
import StrandDesign

/// The real logger sits above the existing Events cards. Sample physiology is not used as logged data.
struct ManualEventLoggingSection: View {
    @ObservedObject var center: ManualEventCenter = .shared
    @State private var editor: EventEditorRequest?
    @State private var library: EventLibraryPage?
    @State private var exportURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Event log").font(StrandFont.title2)
                        Text("Log activities and symptoms.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("Event types", systemImage: "tag") { library = .types }
                        Button("Duration presets", systemImage: "timer") { library = .presets }
                        Button("All logged events", systemImage: "list.bullet") { library = .history }
                        Button("Archive (trash)", systemImage: "archivebox") { library = .archive }
                        Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await center.syncNow() }
                        }
                        Button("Export event history", systemImage: "square.and.arrow.up") { exportURL = center.export() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(StrandFont.title2).frame(width: 44, height: 44)
                    }
                    .disabled(center.owner == nil)
                    .accessibilityLabel("Event log actions")
                }
                Label {
                    Text("Always use the same label for each event type to improve classification accuracy.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "info.circle") }
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)

                if center.owner == nil {
                    Text("Sign in to your Nara account to log and sync your events.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Button("Sign in", systemImage: "person.crop.circle") { library = .account }
                        .buttonStyle(.borderedProminent).tint(StrandPalette.metricPurple).foregroundStyle(.white)
                } else {
                    let favorites = center.types.filter(\.favorite)
                    if !favorites.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("FAVORITES").font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(favorites) { type in
                                        Button { editor = EventEditorRequest(typeId: type.id) } label: {
                                            Label(type.label, systemImage: type.symbol)
                                                .font(StrandFont.subhead).padding(.horizontal, 12).frame(minHeight: 44)
                                                .background(StrandPalette.metricPurple.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain).foregroundStyle(StrandPalette.textPrimary)
                                        .accessibilityHint("Opens the time and duration controls for this event")
                                    }
                                }
                            }
                        }
                    }
                    Button { editor = EventEditorRequest() } label: {
                        Label("Log Event", systemImage: "plus")
                            .font(StrandFont.headline).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.metricPurple)
                    HStack(spacing: 6) {
                        if center.syncing { ProgressView().controlSize(.small) }
                        else { Image(systemName: center.pendingIds.isEmpty ? "checkmark.icloud" : "icloud.and.arrow.up") }
                        Text(center.syncing ? "Syncing events…" : center.pendingIds.isEmpty ? "Synced to your account" : "Saved on this device · sync pending")
                        Spacer()
                        Button { library = .archive } label: {
                            Label("\(center.archived.count)", systemImage: "archivebox")
                        }
                        .accessibilityLabel("Archive, \(center.archived.count) retained entries")
                    }
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    if let message = center.syncMessage {
                        Text(message).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if !center.rejected.isEmpty {
                        Text("\(center.rejected.count) \(center.rejected.count == 1 ? "entry was" : "entries were") not accepted by the cloud and stay on this device only.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                    }
                    if let exportURL { ShareLink("Share event history JSON", item: exportURL) }
                }
                if let error = center.errorMessage {
                    Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                }
            }
            .padding(20).naraCard()

            if !center.events.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your logged events").font(StrandFont.headline)
                        Spacer()
                        Button("See all") { library = .history }.font(StrandFont.caption)
                    }
                    ForEach(center.events.prefix(3)) { event in
                        ManualEventRow(entry: event, center: center) { editor = EventEditorRequest(event: event) }
                    }
                }
            }
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .sheet(item: $editor) { request in
            ManualEventEditor(center: center, request: request, owner: center.owner)
        }
        .sheet(item: $library) { page in
            if page == .account { NaraAccountView() }
            else { ManualEventLibrary(center: center, page: page) }
        }
        .onChange(of: center.owner) { _ in editor = nil; library = nil; exportURL = nil }
        .task {
            await center.syncNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await center.syncNow() }
            }
        }
    }
}

private struct EventEditorRequest: Identifiable {
    let id = UUID()
    var typeId: UUID?
    var event: ManualEventEntry?
}

private enum EventLibraryPage: String, Identifiable {
    case history, archive, types, presets, account
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: "Logged events"
        case .archive: "Archive (trash)"
        case .types: "Event types"
        case .presets: "Duration presets"
        case .account: "Nara account"
        }
    }
}

private struct ManualEventRow: View {
    let entry: ManualEventEntry
    @ObservedObject var center: ManualEventCenter
    var edit: () -> Void
    @State private var confirmingArchive = false
    @State private var showingDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.symbol).font(StrandFont.headline)
                .foregroundStyle(StrandPalette.metricPurple).frame(width: 32, height: 36)
                .accessibilityHidden(true)
            Button { showingDetail = true } label: { details }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what your strap measured around this event")
            Spacer(minLength: 0)
            if entry.isRunning {
                Button("End") { center.stop(entry) }.buttonStyle(.bordered)
                    .accessibilityLabel("End \(entry.label) event")
            }
            Menu {
                if entry.archived {
                    Button("Restore", systemImage: "arrow.uturn.backward") { center.restore(entry) }
                } else {
                    Button("Edit event", systemImage: "pencil") { edit() }
                    Button("Archive event", systemImage: "archivebox") { confirmingArchive = true }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("Actions for \(entry.label)")
        }
        .padding(14).naraCard(radius: 16)
        .sheet(isPresented: $showingDetail) { ManualEventDetailView(entry: entry, center: center) }
        .alert("Archive this event?", isPresented: $confirmingArchive) {
            Button("Archive") { center.archive(entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will not be deleted, but rather archived, because the data exists in the cloud.")
        }
    }
}

extension ManualEventRow {
    @ViewBuilder fileprivate var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.label).font(StrandFont.headline)
            if let start = entry.start {
                Text(start.formatted(date: .abbreviated, time: .shortened))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if entry.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Running · \(ManualEventFormat.duration(context.date.timeIntervalSince(start)))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.metricPurple)
                    }
                } else if let end = entry.end {
                    Text("To \(end.formatted(date: .abbreviated, time: .shortened)) · \(ManualEventFormat.duration(end.timeIntervalSince(start)))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let note = entry.note, !note.isEmpty { Text(note).font(StrandFont.subhead) }
            if let summary = ManualEventFormat.summary(center.contexts[entry.id]) {
                Label(summary, systemImage: "waveform.path.ecg")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            if entry.archived {
                Label("Archived · permanently retained", systemImage: "archivebox")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Text(ManualEventFormat.syncStatus(entry: entry, center: center))
                .font(StrandFont.caption).foregroundStyle(center.rejected[entry.id] == nil
                    ? StrandPalette.textTertiary : StrandPalette.statusCritical)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ManualEventEditor: View {
    @ObservedObject var center: ManualEventCenter
    let request: EventEditorRequest
    let owner: String?
    @Environment(\.dismiss) private var dismiss
    @State private var typeId: UUID?
    @State private var note = ""
    @State private var live = false
    @State private var window = ManualEventWindow(endingAt: Date(), durationMinutes: 5)
    @State private var offsetMinutes: Double = 0
    @State private var previousOffset: Double = 0
    @State private var lookback = 60
    @State private var selectedPreset: UUID?
    @State private var customTypeName = ""
    @State private var customTypeSymbol = "tag.fill"
    @State private var customTypeKind: ManualEventEntry.ActivityKind = .other
    @State private var customTypeOpen = false
    @State private var presetOpen = false
    @State private var presetName = ""
    @State private var presetMinutes = 5

    private var availableTypes: [ManualEventEntry] {
        var types = center.types
        if let event = request.event, let id = event.typeId {
            let historical = ManualEventEntry(id: id, kind: .eventType, label: event.label, symbol: event.symbol,
                                              activityKind: event.activityKind)
            if let index = types.firstIndex(where: { $0.id == id }) { types[index] = historical }
            else { types.append(historical) }
        }
        return types
    }
    private var type: ManualEventEntry? { availableTypes.first { $0.id == typeId } }
    private var isValid: Bool { type != nil && (live || window.end >= window.start) && owner == center.owner }
    private var title: String { request.event == nil ? "Log Event" : "Edit event" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    typeSection
                    if request.event == nil {
                        Picker("Logging mode", selection: $live) {
                            Text("Time window").tag(false)
                            Text("Start / stop").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if !live { timeSection }
                    else {
                        Label("Start now. End this event from the Events page.", systemImage: "record.circle")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Notes").font(StrandFont.headline)
                        TextField("What should you remember?", text: $note, axis: .vertical)
                            .lineLimit(3...6).textFieldStyle(.roundedBorder)
                        Text("Optional · keep the label consistent and add details here.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if let error = center.errorMessage {
                        Text(error).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusCritical)
                    }
                    Button(action: save) {
                        Label(live ? "Start event" : request.event == nil ? "Save event" : "Save changes",
                              systemImage: live ? "play.fill" : "checkmark")
                            .font(StrandFont.headline).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.metricPurple).disabled(!isValid)
                    Text("Saved on this device, then synced to your account. Edits and archives retain the original record.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(20).frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(StrandPalette.surfaceBase).foregroundStyle(StrandPalette.textPrimary)
            .tint(StrandPalette.metricPurple)
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear(perform: prepare)
        }
        .frame(minWidth: 300, minHeight: 500)
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Event type").font(StrandFont.headline)
                Spacer()
                Button { customTypeOpen.toggle() } label: { Label("Custom", systemImage: "plus") }
                    .font(StrandFont.subhead)
            }
            Menu {
                ForEach(availableTypes.sorted { a, b in a.favorite && !b.favorite }) { option in
                    Button { typeId = option.id } label: { Label(option.label, systemImage: option.symbol) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: type?.symbol ?? "tag.fill")
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.metricPurple)
                        .frame(width: 44, height: 44)
                        .background(StrandPalette.metricPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    Text(type?.label ?? "Choose event type").font(StrandFont.headline)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(StrandPalette.textSecondary)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 44).naraCard(radius: 16)
            }.buttonStyle(.plain).accessibilityLabel("Choose event type")
                .accessibilityValue(type?.label ?? "No type selected")
            if let type = center.types.first(where: { $0.id == typeId }) {
                Button { center.toggleFavorite(type) } label: {
                    Label(type.favorite ? "Favorite type" : "Add to favorites", systemImage: type.favorite ? "star.fill" : "star")
                }.font(StrandFont.caption)
            }
            if customTypeOpen {
                TextField("Custom event label", text: $customTypeName).textFieldStyle(.roundedBorder)
                ManualEventIconPicker(selection: $customTypeSymbol)
                ManualEventKindPicker(selection: $customTypeKind)
                Button("Create event type") {
                    let entry = ManualEventEntry(id: UUID(), kind: .eventType, label: customTypeName, symbol: customTypeSymbol,
                                                 activityKind: customTypeKind.rawValue)
                    if center.save(entry, for: owner) {
                        typeId = entry.id; customTypeOpen = false; customTypeName = ""; customTypeSymbol = "tag.fill"
                        customTypeKind = .other
                    }
                }.disabled(customTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Use the same label each time this kind of event occurs.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Duration presets").font(StrandFont.headline)
                Spacer()
                Button { presetOpen.toggle() } label: { Image(systemName: "plus.circle") }.frame(width: 44, height: 44)
                    .accessibilityLabel("Create a duration preset")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(center.presets.filter { $0.typeId == nil || $0.typeId == typeId }) { preset in
                        Button {
                            selectedPreset = preset.id
                            window = ManualEventWindow(endingAt: Date(), durationMinutes: preset.durationMinutes ?? 5)
                            offsetMinutes = 0; previousOffset = 0
                        } label: {
                            VStack(spacing: 3) {
                                Text(preset.label).font(StrandFont.subhead.weight(.semibold))
                                if preset.typeId != nil {
                                    Text("\(preset.durationMinutes ?? 5) min").font(StrandFont.caption)
                                }
                            }
                            .padding(.horizontal, 14).frame(minHeight: 48)
                            .background(selectedPreset == preset.id ? StrandPalette.metricPurple.opacity(0.2) : StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedPreset == preset.id ? StrandPalette.metricPurple : .clear))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if presetOpen {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Preset name, e.g. Morning walk", text: $presetName).textFieldStyle(.roundedBorder)
                    Stepper("\(presetMinutes) minutes", value: $presetMinutes, in: 1...1440)
                    HStack {
                        Text("Minutes")
                        TextField("Minutes", value: $presetMinutes, format: .number)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                    }.font(StrandFont.subhead)
                    Text("Saved for the selected event type.").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Button("Save custom preset") {
                        let preset = ManualEventEntry(id: UUID(), kind: .preset, label: presetName,
                            symbol: "timer", typeId: typeId, durationMinutes: presetMinutes)
                        if center.save(preset, for: owner) {
                            presetOpen = false; presetName = ""; selectedPreset = preset.id
                            window = ManualEventWindow(endingAt: Date(), durationMinutes: presetMinutes)
                            offsetMinutes = 0; previousOffset = 0
                        }
                    }.disabled(type == nil || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || !(1...1440).contains(presetMinutes))
                }.padding(14).naraCard(radius: 14)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("START").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(window.start, format: .dateTime.hour().minute()).font(StrandFont.headline).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(window.start, format: .dateTime.month(.abbreviated).day()).font(StrandFont.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                        Text("\(max(0, Int(window.durationMinutes))) min").font(StrandFont.caption).monospacedDigit()
                    }.foregroundStyle(StrandPalette.metricPurple)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("END").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(window.end, format: .dateTime.hour().minute()).font(StrandFont.headline).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(window.end, format: .dateTime.month(.abbreviated).day()).font(StrandFont.caption)
                    }.frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
                Text("Move the whole window").font(StrandFont.subhead.weight(.semibold))
                Picker("Time range", selection: $lookback) {
                    Text("1 hour").tag(60); Text("6 hours").tag(360); Text("24 hours").tag(1440)
                }.pickerStyle(.segmented)
                    .onChange(of: lookback) { value in offsetMinutes = max(-Double(value), offsetMinutes) }
                Slider(value: $offsetMinutes, in: -Double(lookback)...0, step: 1)
                    .tint(StrandPalette.metricPurple)
                    .accessibilityLabel("Move the event window")
                    .accessibilityValue("\(abs(Int(offsetMinutes))) minutes earlier than ending now")
                    .onChange(of: offsetMinutes) { value in
                        window.shift(minutes: value - previousOffset)
                        previousOffset = value
                    }
                HStack {
                    Text("\(lookback == 60 ? 1 : lookback / 60) h earlier")
                    Spacer()
                    Text("Ends now")
                }.font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                HStack {
                    Button("Start now") { moveStartToNow() }
                    Spacer()
                    Button("End now") { moveEndToNow() }
                }.font(StrandFont.subhead)
            }.padding(18).naraCard()
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Start time", selection: $window.start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End time", selection: $window.end, displayedComponents: [.date, .hourAndMinute])
                if window.end < window.start {
                    Text("End time must be at or after start time.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                } else if window.end > Date() {
                    Text("This window ends in the future. Adjust it if the event has already ended.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }.font(StrandFont.subhead)
        }
    }

    private func prepare() {
        typeId = request.typeId ?? request.event?.typeId ?? center.types.first(where: \.favorite)?.id ?? center.types.first?.id
        if let event = request.event {
            note = event.note ?? ""; live = event.isRunning
            window.start = event.start ?? Date(); window.end = event.end ?? Date()
        } else {
            selectedPreset = center.presets.first { $0.durationMinutes == 5 && $0.typeId == nil }?.id
        }
    }

    private func moveStartToNow() {
        let duration = max(0, window.end.timeIntervalSince(window.start))
        window.start = Date(); window.end = window.start.addingTimeInterval(duration)
        offsetMinutes = 0; previousOffset = 0
    }

    private func moveEndToNow() {
        let duration = max(0, window.end.timeIntervalSince(window.start))
        window.end = Date(); window.start = window.end.addingTimeInterval(-duration)
        offsetMinutes = 0; previousOffset = 0
    }

    private func save() {
        guard let type else { return }
        var event = request.event ?? ManualEventEntry(id: UUID(), kind: .event, label: type.label)
        event.typeId = type.id; event.label = type.label; event.symbol = type.symbol; event.note = note
        // Like the label, the kind is fixed when the event is logged, so later type edits never relabel it.
        event.activityKind = center.activityKind(for: type)
        event.startUnixSeconds = request.event != nil || !live ? window.start.timeIntervalSince1970 : Date().timeIntervalSince1970
        event.endUnixSeconds = live ? nil : window.end.timeIntervalSince1970
        if request.event == nil { event.deviceId = AppModel.shared?.deviceRegistry?.activeDeviceId }
        if center.save(event, for: owner) { dismiss() }
    }
}

private struct ManualEventLibrary: View {
    @ObservedObject var center: ManualEventCenter
    let page: EventLibraryPage
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editing: EventEditorRequest?
    @State private var editingType: ManualEventEntry?
    @State private var pendingArchive: ManualEventEntry?

    private var rows: [ManualEventEntry] {
        let all: [ManualEventEntry]
        switch page {
        case .history: all = center.events
        case .archive: all = center.archived
        case .types: all = center.types
        case .presets: all = center.presets
        case .account: all = []
        }
        return all.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if page == .archive {
                        Label("Entries in this archive are kept permanently. You can restore them at any time.", systemImage: "archivebox")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if page == .types {
                        Text("Star your frequent types. Renaming a type keeps labels on earlier events unchanged.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Button("Create event type", systemImage: "plus") {
                            editingType = ManualEventEntry(id: UUID(), kind: .eventType, label: "")
                        }.buttonStyle(.bordered)
                    }
                    if page == .presets {
                        Text("Create a preset in Log Event. Each preset can have its own event type and duration.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if rows.isEmpty {
                        Label(page == .archive ? "Archive is empty" : "No entries here yet",
                              systemImage: page == .archive ? "archivebox" : "tag")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    ForEach(rows) { entry in
                        if entry.kind == .event {
                            ManualEventRow(entry: entry, center: center) { editing = EventEditorRequest(event: entry) }
                        } else { catalogRow(entry) }
                    }
                }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(StrandPalette.surfaceBase).foregroundStyle(StrandPalette.textPrimary)
            .navigationTitle(page.title).searchable(text: $search, prompt: "Find a label")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { ManualEventEditor(center: center, request: $0, owner: center.owner) }
            .sheet(item: $editingType) { ManualEventCatalogEditor(center: center, initial: $0, owner: center.owner) }
            .alert("Archive this entry?", isPresented: Binding(get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } })) {
                Button("Archive") { if let entry = pendingArchive { center.archive(entry) }; pendingArchive = nil }
                Button("Cancel", role: .cancel) { pendingArchive = nil }
            } message: { Text("This will not be deleted, but rather archived, because the data exists in the cloud.") }
        }.frame(minWidth: 300, minHeight: 500)
    }

    private func catalogRow(_ entry: ManualEventEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol).foregroundStyle(StrandPalette.metricPurple).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.label).font(StrandFont.headline)
                if let duration = entry.durationMinutes {
                    Text("\(duration) min\(entry.typeId.flatMap { id in center.entries.first { $0.id == id }?.label }.map { " · \($0)" } ?? "")")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if entry.archived { Text("Archived · retained").font(StrandFont.caption) }
            }
            Spacer()
            if entry.kind == .eventType && !entry.archived {
                Button { center.toggleFavorite(entry) } label: {
                    Image(systemName: entry.favorite ? "star.fill" : "star").frame(width: 44, height: 44)
                }.accessibilityLabel(entry.favorite ? "Remove \(entry.label) from favorites" : "Favorite \(entry.label)")
            }
            Menu {
                if entry.archived { Button("Restore") { center.restore(entry) } }
                else {
                    Button("Edit") { editingType = entry }
                    Button("Archive") { pendingArchive = entry }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("Actions for \(entry.label)")
        }.padding(14).naraCard(radius: 16)
    }
}

private struct ManualEventCatalogEditor: View {
    @ObservedObject var center: ManualEventCenter
    let initial: ManualEventEntry
    let owner: String?
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var minutes = 5
    @State private var favorite = false
    @State private var symbol = "tag.fill"
    @State private var activityKind: ManualEventEntry.ActivityKind = .other
    var body: some View {
        NavigationStack {
            Form {
                TextField(initial.kind == .preset ? "Preset name" : "Event label", text: $label)
                if initial.kind == .preset {
                    Stepper("\(minutes) minutes", value: $minutes, in: 1...1440)
                    TextField("Minutes", value: $minutes, format: .number)
                }
                else {
                    ManualEventIconPicker(selection: $symbol)
                    ManualEventKindPicker(selection: $activityKind)
                    Toggle("Favorite", isOn: $favorite)
                }
                Text("Use the same label for the same kind of event. Earlier event records keep their original label.")
                if let error = center.errorMessage { Text(error).foregroundStyle(StrandPalette.statusCritical) }
            }
            .navigationTitle(initial.kind == .preset ? "Edit preset" : "Event type")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var next = initial; next.label = label; next.favorite = favorite
                        next.symbol = symbol
                        if next.kind == .preset { next.durationMinutes = minutes }
                        // Only a change is written, so a factory type keeps its seed until it is edited.
                        if next.kind == .eventType && activityKind != initial.effectiveActivityKind ?? .other {
                            next.activityKind = activityKind.rawValue
                        }
                        if center.save(next, for: owner) { dismiss() }
                    }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || owner != center.owner
                               || (initial.kind == .preset && !(1...1440).contains(minutes)))
                }
            }
            .onAppear {
                label = initial.label; minutes = initial.durationMinutes ?? 5; favorite = initial.favorite; symbol = initial.symbol
                activityKind = initial.effectiveActivityKind ?? .other
            }
        }.frame(minWidth: 300, minHeight: 350)
    }
}

/// What the type counts as for the activity classifier. Walking, running, cycling, stairs and rest become
/// training and evaluation labels for it; exercise is compared with it; "Not an activity" is neither.
private struct ManualEventKindPicker: View {
    @Binding var selection: ManualEventEntry.ActivityKind
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Counts as", selection: $selection) {
                ForEach(ManualEventEntry.ActivityKind.allCases) { Text($0.title).tag($0) }
            }
            Text(selection == .other ? "Not compared with activity detection."
                 : "Nara compares these events with what your strap detected, and uses them to improve activity detection.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ManualEventIconPicker: View {
    @Binding var selection: String
    private static let icons: [(symbol: String, title: String)] = [
        ("tag.fill", "Label"), ("star.fill", "Star"), ("heart.fill", "Heart"),
        ("figure.walk", "Walk"), ("figure.run", "Run"), ("dumbbell.fill", "Exercise"),
        ("bicycle", "Cycle"), ("leaf.fill", "Rest"), ("moon.fill", "Sleep"),
        ("sun.max.fill", "Sun"), ("drop.fill", "Water"), ("flame.fill", "Heat"),
        ("brain.head.profile", "Mind"), ("music.note", "Music"), ("briefcase.fill", "Work"),
        ("book.fill", "Study"), ("mappin.and.ellipse", "Location"), ("bubble.left.fill", "Chat"),
        ("clock.fill", "Time"), ("flag.fill", "Flag"), ("fork.knife", "Food"),
        ("cup.and.saucer.fill", "Coffee"), ("pills.fill", "Medicine"), ("hand.wave.fill", "Hand"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Choose an icon").font(StrandFont.headline)
                Spacer()
                Image(systemName: selection).foregroundStyle(StrandPalette.metricPurple)
                    .font(StrandFont.title2).accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                ForEach(Self.icons, id: \.symbol) { icon in
                    Button { selection = icon.symbol } label: {
                        Image(systemName: icon.symbol).font(StrandFont.title2)
                            .foregroundStyle(selection == icon.symbol ? Color.white : StrandPalette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(selection == icon.symbol ? StrandPalette.metricPurple : StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).accessibilityLabel(icon.title)
                    .accessibilityValue(selection == icon.symbol ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selection == icon.symbol ? .isSelected : [])
                }
            }
        }.padding(.vertical, 8)
    }
}

#if DEBUG
/// Uses an in-memory store and no server URL, so simulator screenshots cannot upload fixture labels.
struct ManualEventDemoView: View {
    var showEditor = false
    var showCustomType = false
    var showDetail = false
    var showEventPage = false
    @StateObject private var center: ManualEventCenter
    init(showEditor: Bool = false, showCustomType: Bool = false, showDetail: Bool = false, showEventPage: Bool = false) {
        self.showEventPage = showEventPage
        self.showEditor = showEditor
        self.showCustomType = showCustomType
        self.showDetail = showDetail
        let id = CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
            sourceId: "33333333-3333-4333-8333-333333333333", tokenId: "fixture", uploadToken: "fixture")
        let center = ManualEventCenter(store: try! ManualEventStore(path: ":memory:"), automaticallySync: false,
                                       identity: { id }, endpoint: { nil })
        center.bindAccount()
        let walking = center.types.first { $0.label == "Walking" }!
        let event = ManualEventEntry(id: UUID(), kind: .event, label: walking.label, symbol: walking.symbol,
            typeId: walking.id, startUnixSeconds: Date().addingTimeInterval(-3600).timeIntervalSince1970,
            endUnixSeconds: Date().addingTimeInterval(-1800).timeIntervalSince1970, note: "Walk after lunch")
        _ = center.save(event, for: id.ownerId)
        if let context = Self.sampleContext(for: event) { center.showContextForPreview(context, for: event.id) }
        _center = StateObject(wrappedValue: center)
    }

    /// A context shaped like the server's, for a 30-minute walk an hour ago (sample numbers, never uploaded).
    private static func sampleContext(for event: ManualEventEntry) -> ManualEventContext? {
        let start = event.startUnixSeconds ?? 0, end = event.endUnixSeconds ?? 0
        let bins: [[Double]] = stride(from: start - 1800, to: end + 1800, by: 60).map { t in
            let bpm = t < start ? 64 + sin(t / 300) * 2 : t < end ? 108 + sin(t / 200) * 6 : 78 - (t - end) / 300
            return [t, bpm.rounded(), bpm - 4, bpm + 4, 60]
        }
        let hrv: [[Double]] = stride(from: start - 1800, to: end + 1800, by: 300).map { (t: Double) -> [Double] in
            let value: Double = t < start ? 52 : (t < end ? 31 : 44)
            return [t, value, 300]
        }
        let movement: [[Double]] = stride(from: start - 1800, to: end + 1800, by: 60).map { (t: Double) -> [Double] in
            let value: Double = t < start ? 0.012 : (t < end ? 0.21 + sin(t / 150) * 0.03 : 0.02)
            return [t, value, 60]
        }
        let json: [String: Any] = [
            "version": "manual-event-context-1", "status": "ready", "final": false, "computed_at": end + 3600,
            "event": ["id": event.id.uuidString, "activity_kind": "walking", "start": start, "end": end],
            "device": ["resolution": "entry"],
            "traces": ["hrv_rmssd_ms": hrv, "movement_g": movement],
            "heart_rate": ["pre": ["n": 1790, "coverage": 0.99, "mean": 64, "min": 58, "max": 71],
                           "during": ["n": 1795, "coverage": 1.0, "mean": 108, "min": 92, "max": 121],
                           "post": ["n": 1780, "coverage": 0.99, "mean": 78, "min": 70, "max": 96],
                           "trace": ["bin_s": 60, "bins": bins]],
            "series": ["during": ["hrv_rmssd_ms": ["value": 31], "steps": ["value": 3120], "resp_rate_bpm": ["value": 17.2]]],
            "activity": ["during": ["covered_s": 1800, "coverage": 1.0, "classes": [
                ["class": "walking", "seconds": 1260, "confidence": 0.88], ["class": "brisk_walking", "seconds": 360, "confidence": 0.74],
                ["class": "standing", "seconds": 180, "confidence": 0.61]]],
                "agreement": ["status": "agrees", "activity_kind": "walking", "matched_share": 0.9]],
            "baselines": ["resting_hr_7d": ["value": 57, "buckets": 1900], "hrv_rmssd_7d": ["value": 48, "buckets": 1900]],
            "comparisons": ["hr_during_minus_pre_bpm": 44, "hr_post_minus_pre_bpm": 14, "hr_during_minus_resting_7d_bpm": 51,
                            "hrv_during_minus_7d_ms": -17, "hr_during_minus_type_typical_bpm": 3],
            "exposures": [["kind": "caffeine", "label": "Coffee", "offset_s": -5400]],
            "history": ["previous_count": 6, "typical_hr_during_mean": 105, "typical_from": 6],
            "projections": ["activity_ground_truth": ["status": "projected"]],
            "quality": ["data_through": end + 3000, "missing": [String]()]]
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap(ManualEventContext.decode)
    }

    var body: some View {
        if showEventPage, let event = ManualEventPresentation.events(center).first {
            EventDetailView(event: event, history: ManualEventPresentation.events(center), manual: center)
        } else if showDetail, let event = center.events.first {
            ManualEventDetailView(entry: event, center: center)
        } else if showCustomType {
            ManualEventCatalogEditor(center: center,
                initial: ManualEventEntry(id: UUID(), kind: .eventType, label: "My activity", symbol: "bicycle"), owner: center.owner)
        }
        else if showEditor { ManualEventEditor(center: center, request: EventEditorRequest(), owner: center.owner) }
        // The tab's own routes, so the latest-reaction card and timeline rows open their event page here too.
        else { EventsView(manualEventCenter: center).tabRouteDestinations() }
    }
}
#endif
