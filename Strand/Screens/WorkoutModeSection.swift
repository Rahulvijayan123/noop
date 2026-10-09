import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Workout mode on the strap screen
//
// Tell Nara you are working out (docs/context-watchdog/WORKOUTS.md): pick what kind, and while it runs the strap's
// readings are judged as that workout (an indoor walk expects steps and no route, a ride expects no steps, lifting
// is effort even with the arm still). One workout at a time; a forgotten one ends itself after 4 hours.

struct WorkoutModeSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = WorkoutModeStore.shared

    private enum Sheet: String, Identifiable {
        case start, change, past
        var id: String { rawValue }
    }
    @State private var sheet: Sheet?
    @State private var confirmStop = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = Int(context.date.timeIntervalSince1970)
            let state = WorkoutModeSectionModel(log: store.log, now: now)
            NoopListSection("Workout", footer: state.running
                            ? "Readings are judged as this workout until you stop it. It ends by itself after 4 hours."
                            : "Logging a workout tells Nara you are exercising, so heart rate and movement are judged as exercise.") {
                if state.running { runningRows(state) } else { idleRows(state) }
            }
            .buttonStyle(.plain)
        }
        .onAppear { model.autoEndOverdueWorkout() }
        .sheet(item: $sheet) { which in
            switch which {
            case .start:
                WorkoutTypePickerSheet(title: "Start workout", selected: nil) { type in
                    model.startWorkoutMode(typeId: type.id)
                    sheet = nil
                } onCancel: { sheet = nil }
            case .change:
                WorkoutTypePickerSheet(title: "Change type", selected: store.active?.typeId) { type in
                    model.changeWorkoutType(type.id)
                    sheet = nil
                } onCancel: { sheet = nil }
            case .past:
                PastWorkoutSheet { typeId, start, end in
                    model.logPastWorkout(typeId: typeId, start: start, end: end)
                } onClose: { sheet = nil }
            }
        }
        .alert("Stop workout?", isPresented: $confirmStop) {
            Button("Keep going", role: .cancel) {}
            Button("Stop") { model.stopWorkoutMode() }
        } message: {
            Text("It is saved with its type. A workout shorter than a minute is not kept.")
        }
    }

    @ViewBuilder private func idleRows(_ state: WorkoutModeSectionModel) -> some View {
        Button { sheet = .start } label: {
            NoopListRow(icon: "figure.mixed.cardio", iconColor: StrandPalette.accent, title: "Start workout")
        }
        .accessibilityIdentifier("workoutMode.start")
        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
        Button { sheet = .past } label: {
            NoopListRow(icon: "clock.arrow.circlepath", title: "Log a past workout")
        }
        ForEach(state.recent) { r in
            NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
            NoopListRow(icon: WorkoutTypeIconography.systemSymbolName(for: r.symbol),
                        title: LocalizedStringKey(r.typeName),
                        subtitle: r.autoEnded ? String(localized: "\(r.detail) · Ended after 4 h") : r.detail,
                        showsChevron: false)
                .contextMenu {
                    Button(role: .destructive) { model.deleteLoggedWorkout(id: r.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder private func runningRows(_ state: WorkoutModeSectionModel) -> some View {
        NoopListRow(icon: WorkoutTypeIconography.systemSymbolName(for: state.symbolSport),
                    iconColor: StrandPalette.accent, title: LocalizedStringKey(state.title), subtitle: String(localized: "In progress"),
                    value: state.elapsedText, valueTone: .accent, showsChevron: false)
            .accessibilityIdentifier("workoutMode.running")
        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
        Button { sheet = .change } label: {
            NoopListRow(icon: "arrow.triangle.2.circlepath", title: "Change type")
        }
        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
        Button { confirmStop = true } label: {
            NoopListRow(icon: "stop.circle", iconColor: StrandPalette.statusWarning, title: "Stop workout",
                        showsChevron: false)
        }
        .accessibilityIdentifier("workoutMode.stop")
    }
}

/// The catalogue (`workout-types-1`) as a list to pick from.
struct WorkoutTypePickerSheet: View {
    let title: LocalizedStringKey
    let selected: String?
    var onPick: (WorkoutTypeCatalog.Entry) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                NoopListSection {
                    ForEach(Array(WorkoutTypeCatalog.all.enumerated()), id: \.element.id) { i, type in
                        if i > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        Button { onPick(type) } label: {
                            NoopListRow(icon: WorkoutTypeIconography.systemSymbolName(for: type.sportName),
                                        iconColor: type.id == selected
                                            ? StrandPalette.accent : StrandPalette.textSecondary,
                                        title: LocalizedStringKey(type.name),
                                        value: type.id == selected ? String(localized: "Current") : nil,
                                        valueTone: .accent, showsChevron: false)
                        }
                        .accessibilityIdentifier("workoutType.\(type.id)")
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
            }
        }
    }
}

/// Log a workout that already happened: a type, a start and an end.
private struct PastWorkoutSheet: View {
    var onSave: (String, Date, Date) -> Bool
    var onClose: () -> Void

    @State private var typeId = WorkoutTypeCatalog.all[0].id
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()
    @State private var refused = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $typeId) {
                    ForEach(WorkoutTypeCatalog.all) { Text(LocalizedStringKey($0.name)).tag($0.id) }
                }
                DatePicker("Start", selection: $start, in: ...Date())
                DatePicker("End", selection: $end, in: start...Date())
                if refused {
                    Text("It must end after it starts, last at most 12 hours and not overlap another logged workout.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
            .navigationTitle("Log a past workout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onClose() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(typeId, start, end) { onClose() } else { refused = true }
                    }
                }
            }
        }
    }
}
