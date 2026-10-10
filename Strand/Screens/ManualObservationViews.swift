import SwiftUI
import StrandDesign

/// Observation periods and onset uncertainty: the caregiver evidence the signature engine uses
/// (docs/PHENOTYPE_SIGNATURES.md, "Caregiver evidence").
enum ManualObservationCopy {
    static let explanation = "Log a time when you were watching and logged every event that happened. Nara uses these periods to learn what is normal between events. Observation periods are not events and do not appear in the timeline."
    static let promise = "Every event that happened in this period is logged."

    /// Why a window cannot be saved, or nil when it can.
    static func problem(start: Date, end: Date) -> String? {
        if end <= start { return "The end must be after the start." }
        if end.timeIntervalSince(start) > ManualEventEntry.observationMaxSeconds { return "An observation period can be at most 24 hours. Log a longer time as several periods." }
        return nil
    }

    /// "±5 min" style title for an onset uncertainty.
    static func onsetTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Exact"
        case 60: "±1 h"
        default: "±\(minutes) min"
        }
    }
}

/// "How sure is the start time?" Chosen when the event is logged; the engine aligns each onset within it.
struct ManualEventOnsetPicker: View {
    @Binding var selection: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How sure is the start time?").font(StrandFont.headline)
            Picker("How sure is the start time?", selection: $selection) {
                ForEach(ManualEventEntry.onsetUncertaintyChoices, id: \.self) { minutes in
                    Text(ManualObservationCopy.onsetTitle(minutes)).tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            Text(selection == 0 ? "You saw exactly when it started."
                 : "It started within \(ManualObservationCopy.onsetTitle(selection)) of the time you enter.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One observation period in the library pages.
struct ManualObservationRow: View {
    let entry: ManualEventEntry
    @ObservedObject var center: ManualEventCenter
    var edit: () -> Void
    @State private var confirmingArchive = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ManualEventEntry.observationSymbol).font(StrandFont.headline)
                .foregroundStyle(StrandPalette.metricPurple).frame(width: 32, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Observation period").font(StrandFont.headline)
                if let start = entry.start {
                    Text(ManualEventFormat.range(start: start, end: entry.end))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                let inside = center.events(during: entry).count
                Label(inside == 0 ? "No events logged in this period" : inside == 1 ? "1 event logged in this period"
                      : "\(inside) events logged in this period", systemImage: "checklist")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if let note = entry.note, !note.isEmpty { Text(note).font(StrandFont.subhead) }
                if entry.archived {
                    Label("Archived · permanently retained", systemImage: "archivebox")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Text(ManualEventFormat.syncStatus(entry: entry, center: center))
                    .font(StrandFont.caption).foregroundStyle(center.rejected[entry.id] == nil
                        ? StrandPalette.textTertiary : StrandPalette.statusCritical)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if entry.archived {
                    Button("Restore", systemImage: "arrow.uturn.backward") { center.restore(entry) }
                } else {
                    Button("Edit period", systemImage: "pencil") { edit() }
                    Button("Archive period", systemImage: "archivebox") { confirmingArchive = true }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("Actions for this observation period")
        }
        .padding(14).naraCard(radius: 16)
        .alert("Archive this observation period?", isPresented: $confirmingArchive) {
            Button("Archive") { center.archive(entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will not be deleted, but rather archived, because the data exists in the cloud.")
        }
    }
}

/// Log or edit an observation period: a start, an end (at most 24 h later) and an optional note.
struct ManualObservationEditor: View {
    @ObservedObject var center: ManualEventCenter
    let initial: ManualEventEntry?
    let owner: String?
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date().addingTimeInterval(-7200)
    @State private var end = Date()
    @State private var note = ""

    private var problem: String? { ManualObservationCopy.problem(start: start, end: end) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label {
                        Text(ManualObservationCopy.explanation).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "eye") }
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("When were you watching?").font(StrandFont.headline)
                        DatePicker("From", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("To", selection: $end, displayedComponents: [.date, .hourAndMinute])
                        HStack(spacing: 8) {
                            ForEach([1, 2, 4, 8], id: \.self) { hours in
                                Button("Last \(hours) h") {
                                    end = Date(); start = end.addingTimeInterval(-Double(hours) * 3600)
                                }
                                .buttonStyle(.bordered).font(StrandFont.caption)
                            }
                        }
                        if let problem {
                            Text(problem).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                        } else {
                            Text("\(ManualEventFormat.duration(end.timeIntervalSince(start))) · \(ManualObservationCopy.promise)")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .font(StrandFont.subhead).padding(18).naraCard()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Notes").font(StrandFont.headline)
                        TextField("Where, who was watching, anything unusual", text: $note, axis: .vertical)
                            .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    }
                    if let error = center.errorMessage {
                        Text(error).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusCritical)
                    }
                    Button(action: save) {
                        Label(initial == nil ? "Save observation period" : "Save changes", systemImage: "checkmark")
                            .font(StrandFont.headline).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.metricPurple)
                    .disabled(problem != nil || owner == nil || owner != center.owner)
                    Text("Saved on this device, then synced to your account. Edits and archives retain the original record.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(StrandPalette.surfaceBase).foregroundStyle(StrandPalette.textPrimary)
            .tint(StrandPalette.metricPurple)
            .navigationTitle(initial == nil ? "Observation period" : "Edit observation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                guard let initial else { return }
                start = initial.start ?? start; end = initial.end ?? end; note = initial.note ?? ""
            }
        }
        .frame(minWidth: 300, minHeight: 480)
    }

    private func save() {
        guard problem == nil else { return }
        var entry = initial ?? .observation(start: start, end: end, deviceId: PersonalEventPresentation.canonicalDevice)
        entry.startUnixSeconds = start.timeIntervalSince1970
        entry.endUnixSeconds = end.timeIntervalSince1970
        entry.note = note
        if center.save(entry, for: owner) { dismiss() }
    }
}
