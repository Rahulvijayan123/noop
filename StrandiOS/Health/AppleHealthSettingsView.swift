import SwiftUI
import UIKit
import StrandDesign

/// Settings → Data → Apple Health: connect the two-way HealthKit bridge, see whether it is connected,
/// and sync on demand. The same calls `AppleHealthView` makes; that screen is the macOS data viewer and is
/// not reachable on iPhone.
struct AppleHealthSettingsView: View {
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenScaffold(title: "Apple Health") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                SettingsGroup(footer: footer) {
                    SettingsRow("Status", value: Self.statusLabel(health.auth, syncing: health.syncing), chevron: false)
                        .accessibilityIdentifier("appleHealth.status")
                    if health.auth == .authorized {
                        SettingsDivider()
                        SettingsRow("Last synced", value: lastSyncedLabel, chevron: false)
                    }
                    if let error = health.lastError, health.auth == .authorized {
                        SettingsNote(verbatim: error, tone: StrandPalette.statusWarning)
                    }
                }
                actions
            }
        }
        .onAppear { health.refreshAuthIfPreviouslyGranted() }
    }

    @ViewBuilder
    private var actions: some View {
        switch health.auth {
        case .unknown, .denied:
            SettingsGroup {
                actionRow("Connect Apple Health", id: "appleHealth.connect") {
                    await health.requestAuthorization()
                    await syncAndRefresh()
                }
                if health.auth == .denied {
                    SettingsDivider()
                    actionRow("Open the Health app", id: "appleHealth.openHealth") {
                        if let url = URL(string: "x-apple-health://") { _ = await UIApplication.shared.open(url) }
                    }
                }
            }
        case .authorized:
            SettingsGroup {
                actionRow(health.syncing ? "Syncing…" : "Sync now", id: "appleHealth.sync") {
                    await syncAndRefresh()
                }
                .disabled(health.syncing)
            }
        case .unavailable, .entitlementMissing:
            EmptyView()
        }
    }

    private func actionRow(_ label: LocalizedStringKey, id: String,
                           perform: @escaping () async -> Void) -> some View {
        Button {
            Task { await perform() }
        } label: {
            HStack {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.accent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityIdentifier(id)
    }

    private func syncAndRefresh() async {
        await HealthSyncRefreshCoordinator.run(
            sync: { _ = await health.sync() },
            refresh: { await model.refreshAfterAppleHealthSync(authorized: health.auth == .authorized) }
        )
    }

    private var lastSyncedLabel: String {
        guard let last = health.lastSync else { return String(localized: "Not yet") }
        return last.formatted(.relative(presentation: .named))
    }

    private var footer: LocalizedStringKey? {
        switch health.auth {
        case .authorized:
            return "Nara reads steps and vitals from Apple Health and saves your sleep, heart rate and workouts to it. Choose what's shared in the Health app."
        case .denied:
            return "Allow Nara in the Health app under Sharing → Apps → Nara."
        case .entitlementMissing:
            return "This version of Nara can't connect to Apple Health."
        case .unavailable:
            return "Apple Health isn't available on \(Platform.deviceNounPhrase)."
        case .unknown:
            return nil
        }
    }

    /// The one-word state the Settings row and this page show.
    static func statusLabel(_ auth: HealthKitBridge.AuthState, syncing: Bool) -> String {
        switch auth {
        case .authorized: return syncing ? String(localized: "Syncing…") : String(localized: "Connected")
        case .denied: return String(localized: "Not allowed")
        case .unknown: return String(localized: "Not connected")
        case .unavailable, .entitlementMissing: return String(localized: "Unavailable")
        }
    }
}
