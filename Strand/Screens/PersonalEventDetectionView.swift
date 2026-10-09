import SwiftUI
import StrandDesign

@MainActor
enum PersonalEventPresentation {
    static func events(manual: ManualEventCenter, detection: EventDetectionCenter) -> [HealthEvent] {
        guard let owner = manual.owner, owner == detection.owner else { return [] }
        let types = Dictionary(uniqueKeysWithValues: manual.entries.filter { $0.kind == .eventType }.map { ($0.id, $0) })
        let logged = manual.events.compactMap { entry -> HealthEvent? in
            guard let start = entry.start else { return nil }
            let type = entry.typeId.flatMap { types[$0] }
            return HealthEvent(id: entry.id.uuidString, date: start, title: type?.label ?? entry.label,
                detail: entry.note, symbol: type?.symbol ?? entry.symbol, tone: .normal, origin: .reported,
                physiology: detection.physiology[entry.id.uuidString], recovery: nil,
                typeId: entry.typeId, ownerId: owner, deviceId: entry.deviceId ?? canonicalDevice,
                endDate: entry.end ?? Date())
        }
        let detected = detection.detections.filter { $0.manualEventId == nil && ["pending", "unsure"].contains($0.status) }.map { row in
            HealthEvent(id: row.id.uuidString, date: Date(timeIntervalSince1970: row.start),
                title: types[row.typeId]?.label ?? "Archived event type",
                detail: row.historical ? "Possible event from uploaded history" : "Possible event · Review needed",
                symbol: types[row.typeId]?.symbol ?? "waveform.path.ecg", tone: .detected, origin: .detected,
                physiology: detection.physiology[row.id.uuidString], recovery: nil,
                typeId: row.typeId, ownerId: owner, deviceId: row.deviceId.uuidString,
                endDate: Date(timeIntervalSince1970: row.end))
        }
        return (logged + detected).sorted { $0.date > $1.date }
    }
    static var canonicalDevice: String? {
        IntradaySeriesStore.shared.readCandidates.first { UUID(uuidString: $0) != nil }
    }
}

struct EventDetectionSection: View {
    @ObservedObject var manual: ManualEventCenter
    @ObservedObject var detection: EventDetectionCenter
    @State private var selectedType: ManualEventEntry?
    @State private var review: DetectedEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Detect automatically")
            Text("Choose the events Nara should look for in uploaded sensor data. Each event type uses a model selected for you.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            if let message = detection.message {
                Label(message, systemImage: "icloud").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            if let error = detection.error { Text(error).font(StrandFont.footnote).foregroundStyle(StrandPalette.statusCritical) }
            NoopCard {
                VStack(spacing: NoopMetrics.gap) {
                    ForEach(manual.types) { type in
                        HStack {
                            Button { selectedType = type } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: type.symbol).foregroundStyle(StrandPalette.metricPurple).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(type.label).font(StrandFont.body)
                                        Text(detection.status(type.id)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                    }
                                    Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Toggle(type.label, isOn: Binding(get: { detection.isEnabled(type.id) }, set: { enabled in
                                detection.enqueue(EventDetectionCommand(action: "setting", typeId: type.id, enabled: enabled), expectedOwner: manual.owner)
                            })).labelsHidden().tint(StrandPalette.accent)
                        }
                    }
                }
            }
            let pending = detection.detections.filter { $0.status == "pending" && $0.manualEventId == nil }
            if !pending.isEmpty {
                SectionHeader("Review possible events")
                ForEach(pending.prefix(10)) { item in
                    Button { review = item } label: {
                        NoopCard {
                            HStack {
                                Image(systemName: "waveform.path.ecg").foregroundStyle(StrandPalette.metricPurple)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(manual.entries.first { $0.id == item.typeId }?.label ?? "Event")
                                    Text(Date(timeIntervalSince1970: item.start).formatted(date: .abbreviated, time: .shortened))
                                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer(); Image(systemName: "chevron.right")
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            let retained = detection.detections.filter { ["rejected", "archived", "unsure"].contains($0.status) }
            if !retained.isEmpty {
                DisclosureGroup("Reviewed and archived detections (\(retained.count))") {
                    ForEach(retained) { item in
                        Button { review = item } label: {
                            HStack {
                                Text(manual.entries.first { $0.id == item.typeId }?.label ?? "Event")
                                Spacer(); Text(item.status.capitalized).foregroundStyle(StrandPalette.textSecondary)
                            }.padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                }.font(StrandFont.footnote)
            }
        }
        .sheet(item: $selectedType) { type in DetectorDetailSheet(type: type, owner: manual.owner, detection: detection) }
        .sheet(item: $review) { item in DetectionReviewSheet(item: item, owner: manual.owner, manual: manual, detection: detection) }
        .onChange(of: manual.owner) { _ in selectedType = nil; review = nil }
    }
}

struct DetectorDetailSheet: View {
    let type: ManualEventEntry
    let owner: String?
    @ObservedObject var detection: EventDetectionCenter
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date().addingTimeInterval(-300)
    @State private var end = Date()
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Personal detector") {
                    LabeledContent("Status", value: detection.status(type.id))
                    if let model = detection.settings.first(where: { $0.typeId == type.id }) {
                        if let date = model.lastTrainingAt { LabeledContent("Last evaluation", value: date) }
                        if let reason = model.detail.reason { Text(reason) }
                        if let candidate = model.detail.candidate { LabeledContent("Model", value: candidate) }
                        if let value = model.detail.timeSavedSecondsPerDay {
                            LabeledContent("Estimated time saved", value: String(format: "%.0f sec/day", value))
                        }
                        if let value = model.detail.falseAlertsPerDay { LabeledContent("False alerts", value: String(format: "%.1f/day", value)) }
                        if let value = model.detail.recall { LabeledContent("Reviewed events detected", value: String(format: "%.0f%%", value * 100)) }
                        if let value = model.detail.events { LabeledContent("Evaluation events", value: String(value)) }
                        if let value = model.detail.delaySeconds { LabeledContent("Typical delay", value: String(format: "%.0f sec", value)) }
                    }
                    Text("Models are compared each week when new reviewed data is available. Estimated savings include the time used to confirm and dismiss alerts.")
                }
                Section("Review a time window") {
                    Text("Choose a time when you know this event did not happen. This adds a reviewed negative example for this type only.")
                    DatePicker("Start", selection: $start, in: ...Date())
                    DatePicker("End", selection: $end, in: ...Date())
                    Button(saved ? "Saved for sync" : "No \(type.label) in this window") {
                        guard let device = PersonalEventPresentation.canonicalDevice.flatMap(UUID.init(uuidString:)) else { return }
                        saved = detection.enqueue(EventDetectionCommand(action: "negative", typeId: type.id,
                            start: start.timeIntervalSince1970, end: end.timeIntervalSince1970, deviceId: device), expectedOwner: owner)
                    }.disabled(end <= start || end.timeIntervalSince(start) > 86400 || PersonalEventPresentation.canonicalDevice == nil || saved)
                    if PersonalEventPresentation.canonicalDevice == nil { Text("Connect a cloud-linked wearable to review sensor intervals.") }
                }
            }.navigationTitle(type.label)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct DetectionReviewSheet: View {
    let item: DetectedEvent
    let owner: String?
    @ObservedObject var manual: ManualEventCenter
    @ObservedObject var detection: EventDetectionCenter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: UUID
    @State private var start: Date
    @State private var end: Date
    @State private var archiveWarning = false
    init(item: DetectedEvent, owner: String?, manual: ManualEventCenter, detection: EventDetectionCenter) {
        self.item = item; self.owner = owner; self.manual = manual; self.detection = detection
        _selectedType = State(initialValue: item.typeId)
        _start = State(initialValue: Date(timeIntervalSince1970: item.start))
        _end = State(initialValue: Date(timeIntervalSince1970: item.end))
    }
    private func submit(_ outcome: String) {
        if detection.enqueue(EventDetectionCommand(action: "review", typeId: selectedType,
            detectionId: item.id, outcome: outcome, start: start.timeIntervalSince1970,
            end: end.timeIntervalSince1970), expectedOwner: owner) { dismiss() }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Possible event") {
                    Picker("Event type", selection: $selectedType) {
                        ForEach(manual.types) { type in Label(type.label, systemImage: type.symbol).tag(type.id) }
                    }
                    DatePicker("Start", selection: $start, in: ...Date())
                    DatePicker("End", selection: $end, in: ...Date())
                    Text("Use the same label for the same kind of event. Review the time before you confirm.")
                }
                Section {
                    Button("Confirm event") { submit("confirmed") }
                    Button("Not this event") { submit("rejected") }
                    Button("Unsure") { submit("unsure") }
                    Button("Archive", role: .destructive) { archiveWarning = true }
                }.disabled(end <= start || end.timeIntervalSince(start) > 86400 || !manual.types.contains { $0.id == selectedType })
                if let event = PersonalEventPresentation.events(manual: manual, detection: detection).first(where: { $0.id == item.id.uuidString }) {
                    NavigationLink("View sensor data") { EventDetailView(event: event) }
                }
            }.navigationTitle("Review event")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .alert("Archive event?", isPresented: $archiveWarning) {
                    Button("Archive", role: .destructive) { submit("archived") }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("This will not be deleted, but rather archived, because the data exists in the cloud.") }
        }
    }
}
