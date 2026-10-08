import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import PhotosUI
import StrandDesign
import WhoopStore

/// Settings: grouped rows (label, value, chevron). Each row opens the one page its label names; nothing
/// here routes out to a tab.
///
/// What persists where: the profile (name, date of birth, sex, height, weight) and wear placement sync to
/// Supabase through their own routes (`ProfileCloudSync`, `PlacementCloudSync`), and units, alerts, haptics
/// and the Sana switch follow the account through `SettingsCloudSync`. What names something on this phone
/// (Apple Health access, the double-tap action, Shortcuts), light or dark, and the consents given on it
/// (cycle awareness, Rhythm, sensor biomarkers) stay in its own preferences.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var behavior: BehaviorStore
    @ObservedObject private var naraAuth = NaraAuthService.shared

    /// Profile-photo picker selection (PhotosUI). Cleared back to nil once the bytes are loaded.
    @State private var avatarPickerItem: PhotosPickerItem?

    @State private var dataBusy = false
    @State private var dataAlert: DataAlert?
    @State private var confirmRestore = false
    /// Set when a picked backup is over the size the restore accepts without asking.
    @State private var oversizeRestore: String?
    /// The current manual strap placement (G4), loaded when Settings appears and updated by the editor.
    @State private var currentPlacement = StrapPlacement.unknown

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    /// Light or dark for the whole app; the app roots apply it. Onboarding asks first.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    #if os(iOS)
    @AppStorage(LiquidGlassPrefs.intensityKey) private var liquidGlassPercent = LiquidGlassPrefs.defaultPercent
    #endif
    /// The Sana master switch, under the same `noop.` key Android writes. Off removes the tab and the
    /// assistant entry points (`RootTabView`, `RootView`).
    @AppStorage("noop.coachEnabled") private var sanaEnabled = true
    /// Read through the key (not `SensorBiomarkerFeature.isEnabled`) so the row updates when the page flips it.
    @AppStorage(SensorBiomarkerFeature.enabledKey) private var sensorBiomarkersOn = false

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .imperial }

    var body: some View {
        ScreenScaffold(title: "Settings") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                accountGroup
                profileGroup
                displayGroup
                strapGroup
                alertsGroup
                featuresGroup
                dataGroup
                aboutGroup
            }
        }
        // See `WindowAppearanceSync`: the open Settings sheet follows the Appearance picker.
        .modifier(WindowAppearanceSync(raw: appearanceRaw))
        .alert(dataAlert?.title ?? "", isPresented: Binding(get: { dataAlert != nil },
                                                           set: { if !$0 { dataAlert = nil } }),
               presenting: dataAlert) { _ in
            Button("OK", role: .cancel) { }
        } message: { alert in
            Text(alert.message)
        }
        .confirmationDialog("Restore from a backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Choose backup", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The data on \(Platform.deviceNounPhrase) is replaced by the backup you choose.")
        }
        .alert("Large backup", isPresented: Binding(get: { oversizeRestore != nil },
                                                   set: { if !$0 { oversizeRestore = nil } })) {
            Button("Choose again") { runRestore(allowOversize: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(oversizeRestore ?? "")
        }
        .task { await loadCurrentPlacement() }
    }

    /// Reads the effective placement at "now" for the active strap from the local store. History
    /// before the first declaration is UNKNOWN and is never backfilled (spec §6).
    private func loadCurrentPlacement() async {
        guard let store = await model.repo.storeHandle(),
              let placementStore = try? PlacementStore(dbQueue: store.registryWriter) else { return }
        currentPlacement = Self.activePlacement(placementStore, deviceId: model.repo.deviceId)
        // Pull server-side placement corrections back at the Settings appear cadence. Best-effort;
        // reconcile() self-skips while any local change is still unsynced, so an offline declaration
        // is never overwritten.
        guard CloudPushSettings.isEnabled, CloudPushIdentityStore.current() != nil else { return }
        _ = try? await model.placementSync(placementStore).reconcile()
        currentPlacement = Self.activePlacement(placementStore, deviceId: model.repo.deviceId)
    }

    static func activePlacement(_ store: PlacementStore, deviceId: String) -> StrapPlacement {
        (try? store.activePlacement(at: Date(), deviceId: deviceId))?.placement ?? .unknown
    }

    private func navRow<Dest: View>(_ label: LocalizedStringKey, _ value: String? = nil, id: String,
                                    @ViewBuilder to destination: () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRow(label, value: value)
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityIdentifier("settings.\(id)")
    }

    private func actionRow(_ label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRow(label, value: nil, chevron: false)
        }
        .buttonStyle(SettingsRowStyle())
        .disabled(dataBusy)
        .accessibilityIdentifier("settings.\(id)")
    }

    // MARK: - Account

    private var accountGroup: some View {
        SettingsGroup("Account") {
            navRow("Nara account", accountRowValue, id: "account") {
                NaraAccountView()
            }
        }
    }

    /// What the account row says at a glance: who is signed in, or that nobody is.
    private var accountRowValue: String? {
        guard naraAuth.isAvailable else { return nil }
        switch naraAuth.phase {
        case .signedIn(let signedIn): return signedIn.email ?? String(localized: "Signed in")
        case .signedOut, .awaitingSignupCode, .awaitingRecoveryCode: return String(localized: "Sign in")
        case .choosingSetup: return String(localized: "Finish setup")
        case .restoring: return nil
        }
    }

    // MARK: - Profile

    private var profileGroup: some View {
        SettingsGroup("Profile") {
            navRow("Name", profile.displayName.isEmpty ? String(localized: "Add") : profile.displayName, id: "name") {
                nameEditor
            }
            SettingsDivider()
            navRow("Date of birth", profile.dateOfBirth.formatted(date: .abbreviated, time: .omitted), id: "dateOfBirth") {
                dateOfBirthEditor
            }
            SettingsDivider()
            navRow("Sex", sexLabel, id: "sex") { sexEditor }
            SettingsDivider()
            navRow("Height", heightValue, id: "height") { heightEditor }
            SettingsDivider()
            navRow("Weight", weightValue, id: "weight") { weightEditor }
        }
    }

    // MARK: - Display

    private var displayGroup: some View {
        SettingsGroup("Display") {
            navRow("Appearance", AppearanceMode.resolve(appearanceRaw).label, id: "appearance") {
                appearanceEditor
            }
            #if os(iOS)
            SettingsDivider()
            navRow("Liquid Glass", LiquidGlassSettingsView.valueLabel(liquidGlassPercent), id: "liquidGlass") {
                LiquidGlassSettingsView()
            }
            #endif
        }
    }

    private var sexLabel: String {
        switch profile.sex {
        case "female": return String(localized: "Female")
        case "nonbinary": return String(localized: "Non-binary")
        default: return String(localized: "Male")
        }
    }

    private var weightValue: String {
        unitSystem == .imperial
            ? "\(Int(UnitFormatter.kgToPounds(profile.weightKg).rounded())) lb"
            : String(format: "%.1f kg", profile.weightKg)
    }

    private var heightValue: String {
        if unitSystem == .imperial {
            let parts = UnitFormatter.cmToFeetInches(profile.heightCm)
            return "\(parts.feet)′ \(parts.inches)″"
        }
        return String(format: "%.0f cm", profile.heightCm)
    }

    private var nameEditor: some View {
        let hasAvatar = profile.hasAvatar
        return SettingsEditPage("Name", footnote: "Your photo stays on \(Platform.deviceNounPhrase).") {
            TextField("Your name", text: $profile.displayName)
                #if os(iOS)
                .textContentType(.givenName)
                #endif
                .submitLabel(.done)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, NoopMetrics.space4)
                .frame(minHeight: 52)
                .accessibilityLabel("Name shown in your greeting")
                .accessibilityIdentifier("settings.name.field")
            SettingsDivider()
            HStack(spacing: NoopMetrics.space3) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: NoopMetrics.profileAvatarDiameter)
                    .accessibilityLabel(hasAvatar ? "Your profile photo" : "No profile photo set")
                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    Text(hasAvatar ? "Change photo" : "Choose photo")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                if hasAvatar {
                    Button {
                        profile.clearAvatar()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(NoopButtonStyle(.tertiary))
                    .accessibilityLabel("Remove photo")
                    .accessibilityHint("Reverts to the default profile icon")
                }
            }
            .padding(NoopMetrics.space4)
            // Load the picked photo's bytes, then hand them to the store (which downscales + persists).
            // Clearing the selection afterwards lets the user re-pick the same photo.
            .onChange(of: avatarPickerItem) { newItem in
                guard let newItem else { return }
                Task {
                    let data = try? await newItem.loadTransferable(type: Data.self)
                    await MainActor.run {
                        if let data { profile.setAvatar(data) }
                        avatarPickerItem = nil
                    }
                }
            }
        }
    }

    private var dateOfBirthEditor: some View {
        // #146: age is derived from the date of birth, so it advances on its own.
        SettingsEditPage("Date of birth", footnote: "Age \(profile.age)") {
            DatePicker("Date of birth",
                       selection: $profile.dateOfBirth,
                       in: ProfileStore.dateOfBirthRange,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(StrandPalette.accent)
                .padding(NoopMetrics.space3)
                .accessibilityLabel("Date of birth, age \(profile.age) years")
        }
    }

    private var sexEditor: some View {
        SettingsEditPage("Sex") {
            SettingsOptions(selection: $profile.sex, options: [
                ("male", "Male"), ("female", "Female"), ("nonbinary", "Non-binary"),
            ])
        }
    }

    private var appearanceEditor: some View {
        // `label` is localized where AppearanceMode defines it ("Light" has its own key there, apart from the
        // sleep stage), so it is shown verbatim rather than looked up again.
        SettingsEditPage("Appearance") {
            SettingsOptions(selection: $appearanceRaw,
                            verbatim: AppearanceMode.allCases.map { ($0.rawValue, $0.label) })
        }
    }

    private var weightEditor: some View {
        SettingsEditPage("Weight") {
            FormRow(label: "Weight") {
                // Imperial mode steps in pounds and stores the kg equivalent; metric steps in kg.
                if unitSystem == .imperial {
                    poundsField(weightKg: $profile.weightKg)
                } else {
                    measureField(value: $profile.weightKg, unit: "kg",
                                 range: 30...250, step: 0.5, format: "%.1f",
                                 accessibility: String(localized: "Weight in kilograms"))
                }
            }
            .padding(NoopMetrics.space4)
        }
    }

    private var heightEditor: some View {
        SettingsEditPage("Height") {
            FormRow(label: "Height") {
                // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                if unitSystem == .imperial {
                    feetInchesField(heightCm: $profile.heightCm)
                } else {
                    measureField(value: $profile.heightCm, unit: "cm",
                                 range: 120...230, step: 1, format: "%.0f",
                                 accessibility: String(localized: "Height in centimetres"))
                }
            }
            .padding(NoopMetrics.space4)
        }
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            // The hidden title is the spoken label; a second accessibilityLabel would be read as well.
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
        }
        .fixedSize()
    }

    /// Imperial weight entry: shows pounds, steps in 1-lb increments, and writes the kg equivalent back
    /// to the SI-stored profile. Range mirrors the metric 30…250 kg (≈66…551 lb).
    private func poundsField(weightKg: Binding<Double>) -> some View {
        let lb = Binding<Double>(
            get: { UnitFormatter.kgToPounds(weightKg.wrappedValue) },
            set: { weightKg.wrappedValue = $0 / UnitFormatter.poundsPerKilogram }
        )
        return HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(String(format: "%.0f", lb.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text("lb")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper("Weight in pounds", value: lb, in: 66...551, step: 1)
                .labelsHidden()
                .accessibilityValue("\(Int(lb.wrappedValue.rounded())) pounds")
        }
        .fixedSize()
    }

    /// Imperial height entry: shows feet′ inches″, steps in whole inches, and writes the cm equivalent
    /// back to the SI-stored profile. Range mirrors the metric 120…230 cm (≈47…91 in).
    private func feetInchesField(heightCm: Binding<Double>) -> some View {
        let inches = Binding<Double>(
            get: { UnitFormatter.cmToInches(heightCm.wrappedValue).rounded() },
            set: { heightCm.wrappedValue = $0 * UnitFormatter.centimetersPerInch }
        )
        let parts = UnitFormatter.cmToFeetInches(heightCm.wrappedValue)
        return HStack(spacing: NoopMetrics.space2) {
            Text("\(parts.feet)′ \(parts.inches)″")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: NoopMetrics.formWideValueColumnWidth, alignment: .center)
            Stepper("Height", value: inches, in: 47...91, step: 1)
                .labelsHidden()
                .accessibilityValue("\(parts.feet) feet \(parts.inches) inches")
        }
        .fixedSize()
    }

    // MARK: - Strap

    private var strapGroup: some View {
        SettingsGroup("Strap") {
            NavigationLink {
                StrapConnectionView()
            } label: {
                StrapSettingsRowLabel()
            }
            .buttonStyle(SettingsRowStyle())
            .accessibilityIdentifier("settings.strap")
            SettingsDivider()
            navRow("Wear placement",
                   currentPlacement == .unknown ? String(localized: "Not set") : currentPlacement.displayName,
                   id: "placement") {
                PlacementEditorView(current: $currentPlacement)
            }
        }
    }

    /// "Connected · 64%", in the Pair & connect page's own words. The battery is only shown for a live link:
    /// `batteryPct` keeps the last reading after a disconnect (#2208), and an old level next to
    /// "Not connected" would read as current.
    static func strapRowValue(_ link: StrapLinkInputs) -> String {
        let title = StrapConnectionStatus(link: link).title
        guard link.connected, let pct = link.batteryPct else { return title }
        return "\(title) · \(Int(pct.rounded()))%"
    }

    // MARK: - Alerts & automations

    private var alertsGroup: some View {
        SettingsGroup("Alerts & automations") {
            navRow("Alerts", id: "alerts") { AutomationsView(page: .alerts) }
            SettingsDivider()
            navRow("Double-tap & wear", Self.doubleTapValue(behavior.doubleTapAction), id: "shortcuts") {
                AutomationsView(page: .shortcuts)
            }
            SettingsDivider()
            navRow("Haptics", id: "haptics") { AutomationsView(page: .haptics) }
            #if os(macOS)
            SettingsDivider()
            navRow("Notifications", id: "notifications") { NotificationSettingsView() }
            #endif
        }
    }

    /// The double-tap row's value: the chosen action, or Off.
    static func doubleTapValue(_ action: MacActionKind) -> String {
        switch action {
        case .none: return String(localized: "Off")
        case .runShortcut: return String(localized: "Shortcut")
        default: return action.label
        }
    }

    // MARK: - Features

    private var featuresGroup: some View {
        SettingsGroup("Features") {
            SettingsToggleRow("Sana", isOn: $sanaEnabled)
                .accessibilityIdentifier("settings.sana")
            SettingsDivider()
            navRow("Health insights", id: "healthInsights") { AutomationsView(page: .healthInsights) }
            SettingsDivider()
            navRow("Sensor biomarkers",
                   sensorBiomarkersOn ? String(localized: "On") : String(localized: "Off"),
                   id: "sensorBiomarkers") {
                SensorBiomarkersView()
            }
        }
    }

    // MARK: - Data

    private var dataGroup: some View {
        SettingsGroup("Data") {
            #if os(iOS)
            NavigationLink {
                AppleHealthSettingsView()
            } label: {
                AppleHealthSettingsRowLabel()
            }
            .buttonStyle(SettingsRowStyle())
            .accessibilityIdentifier("settings.appleHealth")
            SettingsDivider()
            #endif
            actionRow("Export backup", id: "exportBackup", action: runExport)
            SettingsDivider()
            actionRow("Restore from backup", id: "restoreBackup") { confirmRestore = true }
            SettingsDivider()
            actionRow("Export CSV", id: "exportCsv", action: runCsvExport)
        }
    }

    // MARK: - About

    private var aboutGroup: some View {
        SettingsGroup("About") {
            SettingsRow("Version", value: Self.versionLabel, chevron: false)
                .accessibilityIdentifier("settings.version")
        }
    }

    /// "11.8.0 (431)": the marketing version and the build, straight from the bundle.
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = UpdateWatch.installedVersion
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }

    // MARK: - Backup and export

    private struct DataAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private func runExport() {
        dataBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    private func runRestore(allowOversize: Bool = false) {
        dataBusy = true
        Task {
            let result = await DataBackup.runImport(allowOversize: allowOversize)
            handleBackup(result)
        }
    }

    private func runCsvExport() {
        dataBusy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            dataBusy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                dataAlert = DataAlert(title: String(localized: "CSV exported"),
                                      message: String(localized: "Saved to \(url.lastPathComponent)."))
            case .failure(let message):
                dataAlert = DataAlert(title: String(localized: "Export problem"), message: message)
            }
        }
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        dataBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            dataAlert = DataAlert(title: String(localized: "Backup exported"),
                                  message: String(localized: "Saved to \(url.lastPathComponent)."))
        case .exportedOversize(let url, let bytes, _):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            dataAlert = DataAlert(title: String(localized: "Backup exported"),
                                  message: String(localized: "Saved to \(url.lastPathComponent). The backup is \(size), so restoring it will ask you to confirm once."))
        case .restoreTooLarge(let name, let limit):
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            oversizeRestore = String(localized: "\(name) is larger than \(cap). Restoring it needs that much free space. Choose the file again to go ahead.")
        case .imported:
            dataAlert = DataAlert(title: String(localized: "Backup restored"),
                                  message: String(localized: "Quit and reopen Nara to load it."))
        case .failure(let message):
            dataAlert = DataAlert(title: String(localized: "Backup problem"), message: message)
        }
    }
}

// MARK: - Live-observing row labels

/// The strap row: the same connection wording as the Pair & connect page, plus the battery while connected.
/// The outer view holds the app-wide objects without reading them; the Equatable inner view reads the link
/// through `StrapLinkObserver`, which only publishes when a link value changes, so the ~1 Hz heart-rate
/// publish does not re-render Settings.
private struct StrapSettingsRowLabel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        StrapSettingsRowValue(model: model, live: live).equatable()
    }
}

private struct StrapSettingsRowValue: View, Equatable {
    let model: AppModel
    let live: LiveState
    @StateObject private var link: StrapLinkObserver

    init(model: AppModel, live: LiveState) {
        self.model = model
        self.live = live
        _link = StateObject(wrappedValue: StrapLinkObserver.bound(to: live, model: model))
    }

    static func == (lhs: StrapSettingsRowValue, rhs: StrapSettingsRowValue) -> Bool {
        lhs.model === rhs.model && lhs.live === rhs.live
    }

    var body: some View {
        SettingsRow("Pair & connect",
                    value: SettingsView.strapRowValue(link.inputs))
            .onAppear { link.refresh() }
    }
}

#if os(iOS)
/// The Apple Health row: whether Nara is connected. Observes the bridge on its own for the same reason.
private struct AppleHealthSettingsRowLabel: View {
    @EnvironmentObject private var health: HealthKitBridge

    var body: some View {
        SettingsRow("Apple Health", value: AppleHealthSettingsView.statusLabel(health.auth, syncing: false))
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return NavigationStack {
        SettingsView()
    }
    .environmentObject(model)
    .environmentObject(model.live)
    .environmentObject(model.profile)
    .environmentObject(model.behavior)
    .frame(width: 402, height: 900)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif

// MARK: - Placement editor (G4)

/// The wear placements a person can declare. "Unknown" is not offered: it is the state of history nobody
/// has annotated, not something to choose, and the store never saves it as a declaration.
enum PlacementChoices {
    static let options: [StrapPlacement] = [.wrist, .bicep, .other]
}

/// Sets the current strap placement. Picking a row declares the change effective at save time
/// (offline-safe), folds it into the local interval model, updates the Settings row, and best-effort
/// uploads the journal through the same authenticated route pattern as the profile/scores routes.
private struct PlacementEditorView: View {
    @EnvironmentObject var model: AppModel
    @Binding var current: StrapPlacement
    @State private var selection = StrapPlacement.unknown.rawValue
    @State private var loaded = false

    var body: some View {
        SettingsEditPage("Wear placement", footnote: "Applies from now on.") {
            SettingsOptions(selection: $selection,
                            options: PlacementChoices.options.map { ($0.rawValue, LocalizedStringKey($0.displayName)) })
        }
        .task { await load() }
        .onChange(of: selection) { newValue in
            guard loaded, let placement = StrapPlacement(rawValue: newValue), placement != current,
                  PlacementChoices.options.contains(placement) else { return }
            Task { await save(placement) }
        }
    }

    private func load() async {
        guard let store = await model.repo.storeHandle(),
              let placementStore = try? PlacementStore(dbQueue: store.registryWriter) else { return }
        let active = SettingsView.activePlacement(placementStore, deviceId: model.repo.deviceId)
        current = active
        selection = active.rawValue
        loaded = true
    }

    private func save(_ placement: StrapPlacement) async {
        guard let store = await model.repo.storeHandle(),
              let placementStore = try? PlacementStore(dbQueue: store.registryWriter) else { return }
        guard (try? placementStore.setCurrent(placement, deviceId: model.repo.deviceId)) != nil else { return }
        current = placement
        // Best-effort upload of the journal. A failure leaves the rows unsynced; the next app activation
        // or save retries them (`AppModel.syncPlacement`).
        await model.syncPlacement()
    }
}

/// Applies the light/dark choice to Settings itself (iOS). Settings opens as a sheet, and a sheet keeps the
/// appearance it was presented with: the app root's `.preferredColorScheme` repaints the screens behind it
/// but not an open sheet or the pages pushed inside it. Stating the scheme on the sheet's own content makes
/// them follow the picker at once. "System" states whatever the device itself is set to.
private struct WindowAppearanceSync: ViewModifier {
    let raw: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content.preferredColorScheme(scheme)
        #else
        content
        #endif
    }

    #if os(iOS)
    private var scheme: ColorScheme {
        switch AppearanceMode.resolve(raw) {
        case .light: return .light
        case .dark: return .dark
        case .system: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
    }
    #endif
}
