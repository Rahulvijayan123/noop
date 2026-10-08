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
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text("What was going on?")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    field("Symptoms") {
                        TextField("Optional", text: $symptoms)
                            .font(StrandFont.body)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, NoopMetrics.space3)
                            .frame(minHeight: NoopMetrics.controlHeight)
                            .background(NoopInsetSurface())
                    }
                    field("Exertion") {
                        chipRow([WatchdogAnnotationExertion.rest, .light, .hard],
                                selection: $exertion, label: MonitorLabels.exertion)
                    }
                    field("Stress") {
                        chipRow([WatchdogAnnotationStress.low, .high],
                                selection: $stress, label: MonitorLabels.stress)
                    }
                    field("Illness") {
                        chipRow([WatchdogAnnotationIllness.feltOff, .not],
                                selection: $illness, label: MonitorLabels.illness)
                    }
                    field("Strap") {
                        chipRow([WatchdogAnnotationSensor.loose, .charging, .justOn, .other],
                                selection: $sensor, label: MonitorLabels.sensor)
                    }
                    Text("Skipping is fine. It is not the same as “no symptoms”, and a note does not change your usual or the daily log.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("After the alert")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        if let pending = store.pendingEpisodeNote {
                            store.saveEpisodeNote(pending.skipped(), deviceId: deviceId)
                        }
                        onClose()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
                    .fontWeight(.semibold)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 480)
        #endif
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            content()
        }
    }

    /// One optional choice: tapping the selected chip clears it.
    private func chipRow<T: Equatable>(_ values: [T], selection: Binding<T?>,
                                       label: @escaping (T) -> String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                let on = selection.wrappedValue == value
                MonitorChip(title: label(value), selected: on) {
                    selection.wrappedValue = on ? nil : value
                }
            }
        }
    }
}
