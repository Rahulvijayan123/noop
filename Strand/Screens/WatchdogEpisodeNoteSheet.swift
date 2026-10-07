import SwiftUI
import StrandDesign
import StrandAnalytics

/// F08: optional note after a sent Watchdog page. Does not write the daily log.
struct WatchdogEpisodeNoteSheet: View {
    @EnvironmentObject private var store: BaselineStore
    let deviceId: String
    var onClose: () -> Void

    @State private var symptoms: String = ""
    @State private var exertion: WatchdogAnnotationExertion?
    @State private var stress: WatchdogAnnotationStress?
    @State private var illness: WatchdogAnnotationIllness?
    @State private var sensor: WatchdogAnnotationSensor?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What was going on when that alert fired? Skipping is fine — it is not the same as “no symptoms,” and it does not change your usual.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    field("Symptoms (optional)") {
                        TextField("Leave blank if you skip", text: $symptoms)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Exertion") {
                        chipRow([WatchdogAnnotationExertion.rest, .light, .hard],
                                selection: $exertion, label: { $0.rawValue })
                    }
                    field("Stress") {
                        chipRow([WatchdogAnnotationStress.low, .high],
                                selection: $stress, label: { $0.rawValue })
                    }
                    field("Illness (note only — not the daily log)") {
                        chipRow([WatchdogAnnotationIllness.feltOff, .not],
                                selection: $illness, label: {
                                    $0 == .feltOff ? "Felt off" : "Not ill"
                                })
                    }
                    field("Strap / sensor") {
                        chipRow([WatchdogAnnotationSensor.loose, .charging, .justOn, .other],
                                selection: $sensor, label: {
                                    switch $0 {
                                    case .loose: return "Loose"
                                    case .charging: return "Charging"
                                    case .justOn: return "Just on"
                                    case .other: return "Other"
                                    }
                                })
                    }
                    NoopButton("Save note", systemImage: "checkmark") {
                        guard let pending = store.pendingEpisodeNote else {
                            onClose()
                            return
                        }
                        let text = symptoms.trimmingCharacters(in: .whitespacesAndNewlines)
                        let saved = pending.entered(
                            nowUnix: Int(Date().timeIntervalSince1970),
                            symptoms: text.isEmpty ? nil : text,
                            exertion: exertion, stress: stress,
                            illness: illness, sensor: sensor, note: nil)
                        store.saveEpisodeNote(saved, deviceId: deviceId)
                        onClose()
                    }
                }
                .padding(NoopMetrics.cardInnerSpacing)
            }
            .navigationTitle("After the alert")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        if let pending = store.pendingEpisodeNote {
                            store.saveEpisodeNote(pending.skipped(), deviceId: deviceId)
                        }
                        onClose()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 480)
        #endif
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            content()
        }
    }

    private func chipRow<T: Equatable>(_ values: [T], selection: Binding<T?>,
                                       label: @escaping (T) -> String) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                let on = selection.wrappedValue == value
                Button(label(value)) {
                    selection.wrappedValue = on ? nil : value
                }
                .font(StrandFont.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? StrandPalette.statusPositive.opacity(0.18) : StrandPalette.surfaceInset)
                )
                .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }
}
