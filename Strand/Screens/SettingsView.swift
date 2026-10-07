import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// Settings: grouped rows (label, value, chevron). Each editable row drills into a small edit page.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var behavior: BehaviorStore
    @ObservedObject private var naraAuth = NaraAuthService.shared

    /// Profile-photo picker selection (PhotosUI). Cleared back to nil once the bytes are loaded.
    @State private var avatarPickerItem: PhotosPickerItem?

    @State private var exportBusy = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""
    @State private var showExportAlert = false
    @State private var showAbout = false
    /// The current manual strap placement (G4), loaded when Settings appears.
    @State private var currentPlacement = StrapPlacement.unknown

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    #if os(iOS)
    @AppStorage("notif.masterEnabled") private var wristAlerts = false
    #endif

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        ScreenScaffold(title: "Settings") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                accountGroup
                profileGroup
                deviceGroup
                automationsGroup
                exportGroup
                appGroup
            }
        }
        .alert(exportAlertTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportAlertMessage)
        }
        .sheet(isPresented: $showAbout) {
            HowNoopWorksView(onClose: { showAbout = false })
        }
        .task { await loadCurrentPlacement() }
    }

    /// Reads the effective placement at "now" for the active strap from the local store. History
    /// before the first declaration is UNKNOWN and is never backfilled (spec §6).
    private func loadCurrentPlacement() async {
        guard let store = await model.repo.storeHandle(),
              let placementStore = try? PlacementStore(dbQueue: store.registryWriter) else { return }
        let device = model.repo.deviceId
        currentPlacement = (try? placementStore.activePlacement(at: Date(), deviceId: device))?.placement
            ?? .unknown
        // F5 (audit-g34-g7-context): pull server-side placement corrections back at the Settings
        // appear cadence. Best-effort and non-blocking; reconcile() self-skips while any local
        // change is still unsynced, so an offline declaration is never overwritten.
        await reconcilePlacement(placementStore)
    }

    /// Best-effort pull of the server's placement intervals (same authenticated route pattern).
    private func reconcilePlacement(_ placementStore: PlacementStore) async {
        guard CloudPushSettings.isEnabled, CloudPushIdentityStore.current() != nil else { return }
        let sync = PlacementCloudSync(store: { placementStore })
        _ = try? await sync.reconcile()
    }

    private func navRow<Dest: View>(_ label: LocalizedStringKey, _ value: String? = nil,
                                    @ViewBuilder to destination: () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRow(label, value: value)
        }
        .buttonStyle(SettingsRowStyle())
    }

    // MARK: - Account

    private var accountGroup: some View {
        SettingsGroup("Account") {
            navRow("Nara account", accountRowValue) {
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
            navRow("Name", profile.displayName.isEmpty ? String(localized: "Add") : profile.displayName) {
                nameEditor
            }
            SettingsDivider()
            navRow("Date of birth", profile.dateOfBirth.formatted(date: .abbreviated, time: .omitted)) {
                dateOfBirthEditor
            }
            SettingsDivider()
            navRow("Sex", sexLabel) { sexEditor }
            SettingsDivider()
            navRow("Units", unitSystem == .imperial ? String(localized: "Imperial") : String(localized: "Metric")) {
                unitsEditor
            }
            SettingsDivider()
            navRow("Weight", weightValue) { weightEditor }
            SettingsDivider()
            navRow("Height", heightValue) { heightEditor }
        }
    }

    private static let profileFootnote: LocalizedStringKey =
        "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."

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
        return SettingsEditPage("Name",
                                footnote: "Optional photo. It stays on \(Platform.deviceNounPhrase) and is never uploaded.") {
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
        SettingsEditPage("Date of birth", footnote: "Age \(profile.age). \(Self.profileFootnote)") {
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
        SettingsEditPage("Sex", footnote: Self.profileFootnote) {
            SettingsOptions(selection: $profile.sex, options: [
                ("male", "Male"), ("female", "Female"), ("nonbinary", "Non-binary"),
            ])
        }
    }

    private var unitsEditor: some View {
        SettingsEditPage("Units", footnote: "Used for weight and height.") {
            SettingsOptions(selection: $unitSystemRaw, options: [
                (UnitSystem.metric.rawValue, "Metric"), (UnitSystem.imperial.rawValue, "Imperial"),
            ])
        }
    }

    private var weightEditor: some View {
        SettingsEditPage("Weight", footnote: Self.profileFootnote) {
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
        SettingsEditPage("Height", footnote: Self.profileFootnote) {
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
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
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
                .accessibilityLabel("Weight, \(Int(lb.wrappedValue.rounded())) pounds")
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
            Stepper("Height in inches", value: inches, in: 47...91, step: 1)
                .labelsHidden()
                .accessibilityLabel("Height, \(parts.feet) feet \(parts.inches) inches")
        }
        .fixedSize()
    }

    // MARK: - Device

    private var deviceGroup: some View {
        SettingsGroup("Device") {
            SettingsRow("Strap", value: strapStatusTitle, chevron: false)
            SettingsDivider()
            if let pct = live.batteryPct {
                SettingsRow("Battery",
                            value: "\(Int(pct.rounded()))%" + (live.charging == true ? " · " + String(localized: "Charging") : ""),
                            chevron: false)
                SettingsDivider()
            }
            navRow("Wear placement",
                   currentPlacement == .unknown ? String(localized: "Not set") : currentPlacement.displayName) {
                placementEditor
            }
            SettingsDivider()
            navRow("Pair & connect") { StrapConnectionView() }
        }
    }

    /// Manual, effective-dated placement (G4). Picking a row declares the placement effective at the
    /// moment it is saved, offline-safe; corrections close the overlapping interval in the local
    /// store and are journaled for upload.
    private var placementEditor: some View {
        PlacementEditorView()
    }

    // Shares LiveState.connectionStatus* with the sidebar footer (RootView) so the two never drift (#266).
    private var strapStatusTitle: String { live.connectionStatusLabel }

    // MARK: - Automations

    private var automationsGroup: some View {
        SettingsGroup("Automations") {
            #if os(iOS)
            navRow("Wrist alerts", wristAlerts ? String(localized: "On") : String(localized: "Off")) {
                AutomationsView()
            }
            SettingsDivider()
            #endif
            navRow("Double-tap", behavior.doubleTapAction.label) { AutomationsView() }
            SettingsDivider()
            navRow("Manage automations") { AutomationsView() }
        }
    }

    // MARK: - Export

    private var exportGroup: some View {
        SettingsGroup("Export", footer: "Exports are not encrypted. Store them somewhere you trust.") {
            exportRow("Export backup", action: runExport)
            SettingsDivider()
            exportRow("Export CSV", action: runCsvExport)
        }
    }

    private func exportRow(_ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRow(label, value: exportBusy ? String(localized: "Working…") : nil, chevron: !exportBusy)
        }
        .buttonStyle(SettingsRowStyle())
        .disabled(exportBusy)
    }

    // MARK: - App

    private var appGroup: some View {
        SettingsGroup("App") {
            #if os(macOS)
            navRow("Notifications") { NotificationSettingsView() }
            SettingsDivider()
            #endif
            navRow("Sensor biomarkers",
                   SensorBiomarkerFeature.isEnabled ? String(localized: "On") : String(localized: "Off")) {
                SensorBiomarkersView()
            }
            SettingsDivider()
            Button { showAbout = true } label: { SettingsRow("About") }
                .buttonStyle(SettingsRowStyle())
        }
    }

    private func runExport() {
        exportBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleExport(result)
        }
    }

    private func runCsvExport() {
        exportBusy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            exportBusy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                exportAlertTitle = String(localized: "CSV exported")
                exportAlertMessage = String(localized: "Saved to \(url.lastPathComponent).")
                showExportAlert = true
            case .failure(let message):
                exportAlertTitle = String(localized: "Export problem")
                exportAlertMessage = message
                showExportAlert = true
            }
        }
    }

    @MainActor
    private func handleExport(_ result: DataBackup.BackupResult) {
        exportBusy = false
        switch result {
        case .cancelled, .imported, .restoreTooLarge:
            return
        case .exported(let url):
            exportAlertTitle = String(localized: "Backup exported")
            exportAlertMessage = String(localized: "Saved to \(url.lastPathComponent).")
            showExportAlert = true
        case .exportedOversize(let url, let bytes, _):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            exportAlertTitle = String(localized: "Backup exported")
            exportAlertMessage = String(localized: "Saved to \(url.lastPathComponent). The database is \(size), so restoring it will ask you to confirm once.")
            showExportAlert = true
        case .failure(let message):
            exportAlertTitle = String(localized: "Export problem")
            exportAlertMessage = message
            showExportAlert = true
        }
    }

}

// MARK: - Grouped-list building blocks

/// A rounded card of rows under a small all-caps title. `footer` is a muted note beneath the card.
/// With no title it is just the card, which the edit pages reuse.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey?
    let footer: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            StrandCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let title {
                        Text(title)
                            .strandOverline()
                            .textCase(.uppercase)
                            .padding(.horizontal, NoopMetrics.space4)
                            .padding(.top, NoopMetrics.space4)
                            .padding(.bottom, NoopMetrics.space1)
                    }
                    content()
                }
            }
            if let footer {
                Text(footer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NoopMetrics.space1)
            }
        }
    }
}

/// Label left; optional value and chevron right.
private struct SettingsRow: View {
    let label: LocalizedStringKey
    let value: String?
    let chevron: Bool

    init(_ label: LocalizedStringKey, value: String? = nil, chevron: Bool = true) {
        self.label = label
        self.value = value
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: NoopMetrics.space3)
            if let value {
                Text(value)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Hairline between rows, inset from the leading edge so it starts under the label text.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.leading, NoopMetrics.space4)
    }
}

struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A pushed page: big title, one card, optional footnote.
private struct SettingsEditPage<Content: View>: View {
    let title: LocalizedStringKey
    let footnote: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, footnote: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        ScreenScaffold(title: title) {
            SettingsGroup(footer: footnote, content: content)
        }
    }
}

/// Single-choice list with a checkmark on the selected row.
private struct SettingsOptions: View {
    @Binding var selection: String
    let options: [(tag: String, label: LocalizedStringKey)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { SettingsDivider() }
                Button {
                    selection = option.tag
                } label: {
                    HStack {
                        Text(option.label)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        if selection == option.tag {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, NoopMetrics.space4)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowStyle())
                .accessibilityAddTraits(selection == option.tag ? .isSelected : [])
            }
        }
    }
}

// MARK: - Steps estimate calibration

/// Small shared formatters for the steps-estimate calibration UI — kept apart from the sheet so the
/// Profile-card summary row and the sheet agree on the confidence wording. Mirrors the Android
/// `StepsCalibrationFormat` object.
enum StepsCalibrationFormat {
    /// A 0–1 confidence as Low / Medium / High — the honest read-out the sheet and the summary row share.
    /// Thirds: < 0.34 Low, < 0.67 Medium, else High. A manual coefficient is confidence 1.0 → "High".
    static func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.34: return String(localized: "Low")
        case ..<0.67: return String(localized: "Medium")
        default:      return String(localized: "High")
        }
    }
}

/// One recent day's estimated-vs-phone steps comparison row, for the sheet's accuracy table.
private struct StepsComparisonRow: Identifiable {
    let day: String          // yyyy-MM-dd
    let estimated: Int
    let actual: Int
    var id: String { day }
    /// Signed error of the estimate against the phone count, as a percentage (estimate − actual) / actual.
    var errorPct: Double { actual > 0 ? Double(estimated - actual) / Double(actual) * 100 : 0 }
}

/// WHOOP 4.0 steps-ESTIMATE calibration — honest explainer + current fit + a recent estimated-vs-phone
/// table + a manual coefficient override with a live preview. Presented as a sheet from Settings →
/// Profile → "Steps estimate". Reads the SAME data the engine fits against (the computed `steps_est`
/// series and the phone's `steps`), never recomputing the headline. Mirrors Android `StepsCalibrationScreen`.
// Internal (not file-private) so the Today Steps tile can present the SAME calibration sheet directly
// when it's showing an ESTIMATE for a WHOOP 4.0 user — one shared entry point, no duplicated screen (H6).
struct StepsCalibrationSheet: View {
    let repo: Repository
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    /// Recent days that have BOTH an estimate and a real phone step count, newest first — the accuracy table.
    @State private var comparison: [StepsComparisonRow] = []
    /// A representative recent motion volume (median of recent days' motion), used so the manual-coefficient
    /// preview reflects a TYPICAL day. nil until loaded / no recent estimated day with a known motion.
    @State private var sampleMotion: Double?

    /// The draft manual coefficient the slider edits, committed to ProfileStore on release. 0 = auto-fit.
    @State private var draftManual: Double = 0
    @State private var didLoad = false

    /// The strap has banked no motion, and we have looked.
    ///
    /// Named once because two places depend on it and they must stay exactly complementary: the
    /// no-motion banner appears, and the calibration countdown does NOT. Written as two separate
    /// expressions they drifted immediately — the guard's first draft tested `sampleMotion == nil`
    /// alone, which is also true during the load, so the countdown vanished in a window where the
    /// banner had not appeared yet and the card explained nothing at all.
    private var strapHasNoMotion: Bool { didLoad && sampleMotion == nil }

    /// #107: the sheet's guidance depends on the strap family. A WHOOP 4.0 streams motion automatically, so
    /// "let it sync" is right; a 5/MG only streams motion once the experimental deep-data unlock is on, so
    /// the 4.0 advice is futile there and the empty state must say so instead.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop5mg.rawValue
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    private var is5MG: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    /// The coefficient the slider's max anchors to — generous headroom over whatever the auto-fit found so
    /// a manual nudge in either direction is reachable. Floor keeps the slider usable before any fit.
    private var sliderMax: Double {
        max(profile.stepsCalibrationCoefficient, profile.stepsManualCoefficient, 50) * 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    explainerCard
                    if strapHasNoMotion { noMotionNote }
                    currentFitCard
                    comparisonCard
                    manualAdjustCard
                }
                .padding(20)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await loadIfNeeded() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Steps estimate").font(StrandFont.overline)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Calibrate your steps").font(StrandFont.rounded(26, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG ? "WHOOP 5.0 / MG · motion → steps" : "WHOOP 4.0 · motion → steps").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done").frame(minWidth: 120)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(NoopMetrics.space4)
    }

    // MARK: Cards

    /// The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc.
    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("How this works", systemImage: "figure.walk.motion")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG
                     ? String(localized: "NOOP estimates your steps from your WHOOP's stored motion, calibrated to your phone's step count. It's an estimate, not a hardware step counter; normal WHOOP 5/MG history sync supplies the motion data.")
                     : String(localized: "NOOP estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter. A WHOOP 4.0 doesn't transmit steps."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the days your phone also counted steps, NOOP learns how much your motion maps to steps, then applies that to the strap-only days. The more matching days it has, the more it trusts the estimate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown when the strap has banked NO motion yet (sampleMotion is nil) — the real reason a fresh
    /// WHOOP 4.0 shows zero steps (#37 bringiton321). Steps are built from the strap's synced motion
    /// history, so without a backfill there is nothing to estimate from — calibration can't help yet.
    ///
    /// #107: family-aware. A 4.0 streams motion automatically → "let it sync" is right. A 5/MG only streams
    /// motion once the experimental deep-data unlock is ON — so on a 5/MG the honest advice is "turn that on
    /// and reconnect", not "wait for a sync" (which never comes). Imports don't supply strap motion either.
    private var noMotionNote: some View {
        NoopCard(tint: StrandPalette.metricAmber) {
            VStack(alignment: .leading, spacing: 10) {
                Label("No motion synced yet", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(noMotionLead)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(noMotionAction)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "why it's empty" line — a 5/MG needs the deep-data unlock before it streams motion at all.
    private var noMotionLead: String {
        if is5MG {
            return String(localized: "We're not seeing motion from your WHOOP 5.0 / MG yet. Keep NOOP connected and let strap history finish syncing; the experimental R22 flags are not required. Account or Apple Health imports do not contain the raw strap motion this estimate needs.")
        }
        return String(localized: "We're not seeing any motion from your strap yet. Steps are estimated from your WHOOP's banked motion history, so your strap needs to sync that history before NOOP has anything to count.")
    }

    /// The "what to do" line — 5/MG points at the deep-data toggle (unless it's already on, then just sync).
    private var noMotionAction: String {
        if is5MG && !deepDataEnabled {
            return String(localized: "Open NOOP near the strap and let WHOOP 5/MG history finish syncing. The step estimate and calibration fill in once enough stored motion has arrived; the legacy R22 experiment is not required.")
        }
        if is5MG {
            return String(localized: "Deep data is on — open NOOP near your strap and let it sync its motion history (a full first-run sync can take a while). Once a day or two of motion lands, your step estimate and the calibration below fill in.")
        }
        return String(localized: "Open NOOP near your strap and let it catch up (a full history sync can take a while on first run). Once a day or two of motion lands, your step estimate and the calibration below will start to fill in.")
    }

    /// The current calibration read-out: coefficient, sample days, and a Low/Medium/High confidence —
    /// or, if nothing's fit yet and no manual value is set, an honest "what we still need" prompt.
    private var currentFitCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current calibration").strandOverline()
                if profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0 {
                    let coeff = profile.stepsManualCoefficient > 0
                        ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.1f", coeff))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.accent)
                        Text("steps per motion unit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if profile.stepsManualCoefficient > 0 {
                        statLine(String(localized: "Source"), String(localized: "Manual (you set this by hand)"))
                    } else {
                        statLine(String(localized: "Fitted from"),
                                 profile.stepsCalibrationSampleDays == 1
                                     ? String(localized: "1 day your phone also counted")
                                     : String(localized: "\(profile.stepsCalibrationSampleDays) days your phone also counted"))
                        statLine(String(localized: "Confidence"), "\(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) · \(Int((profile.stepsCalibrationConfidence * 100).rounded()))%")
                    }
                } else {
                    Text("Not calibrated yet")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // Only ask for phone-step days when phone-step days are what is actually missing.
                    //
                    // A step estimate is `motion * coefficient` (`StepsEstimateEngine.estimate`) and a
                    // calibration point is the ratio `steps / motion`, so BOTH halves are required. With no
                    // banked strap motion neither the estimate nor the fit can move however many days the
                    // phone counts. The countdown below then names the half the user already has and hides
                    // the half they do not — a field report asked whether entering Apple Health steps by
                    // hand would start the calibration, which is exactly the conclusion it invites.
                    //
                    // The no-motion banner at the top of this sheet already explains the real blocker, so
                    // the honest move is to stop competing with it rather than to add more copy.
                    if !strapHasNoMotion {
                    // #589: a concrete countdown instead of a vague "a few days". Headline comes straight
                    // from the engine's needsMoreDays state so the wording matches the Today steps tile.
                    // #693: drive `have` off `profile.stepsCalibrationSampleDays` — the value the engine
                    // persists for the not-yet-calibrated case (IntelligenceEngine.swift sets it to the
                    // usable-day `have`, the SAME source the Today tile reads). `usableMatchedDays` can't be
                    // used here: `loadIfNeeded` early-returns before computing it when coeff == 0 (no fit
                    // yet), so it would always read 0 and the card was stuck on "Need 3 more days".
                    Text(StepsEstimateEngine.CalibrationStatus
                        .needsMoreDays(have: profile.stepsCalibrationSampleDays,
                                       need: StepsEstimateEngine.minCalibrationDays)
                        .headline)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.accent)
                    Text("These are the days where your phone also counted steps, so NOOP can learn how your motion maps to steps. Or set the coefficient manually below.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The accuracy table: recent days that have BOTH an estimate and a phone count, side by side, so the
    /// user can SEE how close the estimate runs. Empty until enough both-have days exist.
    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimated vs your phone").strandOverline()
                if comparison.isEmpty {
                    Text("No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Column header.
                    HStack {
                        Text("Day").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Est.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Phone").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Δ").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    ForEach(comparison) { row in
                        HStack {
                            Text(Self.shortDay(row.day))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.grouped(row.estimated))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Self.grouped(row.actual))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(String(format: "%+.0f%%", row.errorPct))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(abs(row.errorPct) <= 15
                                                 ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Self.shortDay(row.day)): estimated \(row.estimated) steps, phone \(row.actual) steps, \(Int(row.errorPct.rounded())) percent difference")
                    }
                    Text("These days are excluded from the estimate (your phone's real count is shown instead). They're here only so you can judge the estimate's accuracy.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Manual override: a slider bound to a draft, committed on release, with a live preview of what a
    /// typical recent day would estimate at the chosen coefficient. 0 returns to auto-fit.
    private var manualAdjustCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust manually").strandOverline()
                Text("Override the automatic fit with your own steps-per-motion value. Useful if your phone has no step history to learn from, or the estimate runs consistently high or low. Set it back to auto by dragging to the far left.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draftManual > 0 ? String(format: "%.1f", draftManual) : String(localized: "Auto"))
                        .font(StrandFont.number(24))
                        .foregroundStyle(draftManual > 0 ? StrandPalette.accent : StrandPalette.textSecondary)
                    Text(draftManual > 0 ? "steps / motion unit" : "fit from your phone")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                Slider(value: $draftManual, in: 0...sliderMax, step: 0.5) {
                    Text("Manual steps coefficient")
                } minimumValueLabel: {
                    Text("Auto").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } maximumValueLabel: {
                    Text("High").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } onEditingChanged: { editing in
                    // Commit on release — snap a tiny drag back to 0 (auto) so "auto" is reachable.
                    if !editing { profile.stepsManualCoefficient = draftManual < 0.5 ? 0 : draftManual }
                }
                .tint(StrandPalette.accent)
                .accessibilityValue(draftManual > 0
                                    ? "\(String(format: "%.1f", draftManual)) steps per motion unit"
                                    : "Automatic")

                // Live preview: a typical recent day re-estimated at the draft coefficient.
                if let motion = sampleMotion {
                    let effective = draftManual > 0 ? draftManual : profile.stepsCalibrationCoefficient
                    if effective > 0 {
                        let preview = Int((motion * effective).rounded())
                        statLine(String(localized: "A typical recent day"),
                                 draftManual > 0
                                     ? String(localized: "≈ \(Self.grouped(preview)) steps at this setting")
                                     : String(localized: "≈ \(Self.grouped(preview)) steps (auto)"))
                    }
                }
                if draftManual > 0 {
                    Text("Takes effect on the next analytics pass (after the next sync).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A small "label … value" line shared by the fit + preview cards.
    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Data

    /// Build the comparison table + a typical-day motion, once. The engine stores `steps_est` ONLY for
    /// strap-only days (a phone-covered day uses the phone's real count), so an estimate and a phone count
    /// never co-exist in storage. To still SHOW "how close the estimate is", we reconstruct what the
    /// estimate WOULD have been on recent phone-covered days: read each day's motion volume the same way
    /// the engine does (gravity over [localMidnight, +24h)) and run the public `StepsEstimateEngine` with
    /// the live calibration. This reuses the engine, never invents a number, and needs no extra storage.
    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        draftManual = profile.stepsManualCoefficient

        // Effective calibration in force right now: a manual override wins, else the persisted auto-fit.
        let coeff = profile.stepsManualCoefficient > 0
            ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient

        // Phone reference steps from Apple Health daily rows (steps > 0 only), newest first.
        let appleRows = await repo.appleDailyRows()
        let phoneDays = appleRows
            .compactMap { row -> (day: String, steps: Int)? in
                guard let s = row.steps, s > 0 else { return nil }
                return (row.day, s)
            }
            .sorted { $0.day > $1.day }

        // Reconstruct the estimate for the most recent phone-covered days, motion-by-motion.
        guard coeff > 0 else { return }
        let cal = StepsEstimateEngine.Calibration(coefficient: coeff,
                                                  sampleDays: profile.stepsCalibrationSampleDays,
                                                  confidence: profile.stepsCalibrationConfidence,
                                                  manual: profile.stepsManualCoefficient > 0)
        let dayParser = DateFormatter(); dayParser.locale = Locale(identifier: "en_US_POSIX"); dayParser.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var rows: [StepsComparisonRow] = []
        var motions: [Double] = []
        for entry in phoneDays.prefix(10) {           // scan a few extra to fill 7 after motion gaps
            guard let dayDate = dayParser.date(from: entry.day) else { continue }
            let mid = Int(calendar.startOfDay(for: dayDate).timeIntervalSince1970)
            // #1643: the UNION, not `repo.deviceId` alone — a re-added strap leaves motion under both the
            // active id and the canonical one, and reading either by itself makes this screen disagree
            // with the estimator it is supposed to be reconstructing.
            let grav = await repo.gravitySamplesUnion(from: mid, to: mid + 86_400 - 1)
            let motion = StepsEstimateEngine.dayMotionIntensity(grav)
            guard motion > 0, let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
            motions.append(motion)
            rows.append(StepsComparisonRow(day: entry.day, estimated: est, actual: entry.steps))
            if rows.count >= 7 { break }
        }
        comparison = rows
        // #693: the "Need N more days…" countdown is now driven by `profile.stepsCalibrationSampleDays`
        // (the engine-persisted usable-day count, read directly in the card) — NOT a local match count
        // computed here. This scan reaches here ONLY when coeff > 0 (already calibrated), so a local count
        // would never reflect the not-yet-calibrated state the countdown describes. The rows still feed the
        // accuracy table (`comparison`) above.

        // Typical recent day's motion for the live preview = median of the motions we just measured.
        if !motions.isEmpty {
            let s = motions.sorted()
            sampleMotion = s[s.count / 2]
        }
    }

    // MARK: Formatting

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// "yyyy-MM-dd" → "EEE d MMM" for the table's day column.
    private static func shortDay(_ key: String) -> String {
        let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: key) else { return key }
        let outF = DateFormatter(); outF.dateFormat = "EEE d MMM"
        return outF.string(from: d)
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        .environmentObject(model.behavior)
        // iPhone-width (402pt) so the narrow Backup row stays in the preview's blast radius —
        // at 720 the three-up button row had slack and the truncation regression slipped through. (#188)
        .frame(width: 402, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif


// MARK: - Placement editor (G4)

/// Sets the current strap placement. Loads the effective placement when it appears; picking a row
/// declares the change effective at save time (offline-safe), folds it into the local interval
/// model, and best-effort uploads the journal through the same authenticated route pattern as the
/// profile/scores routes. "Not set"/Unknown is the honest state for unannotated history.
private struct PlacementEditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = StrapPlacement.unknown.rawValue
    @State private var loaded = false

    var body: some View {
        SettingsEditPage("Wear placement",
                         footnote: "Where you wear your strap. Placement-aware metric eligibility uses this; days before the first declaration stay unknown.") {
            SettingsOptions(selection: $selection, options: [
                (StrapPlacement.wrist.rawValue, "Wrist"),
                (StrapPlacement.bicep.rawValue, "Bicep"),
                (StrapPlacement.other.rawValue, "Other"),
                (StrapPlacement.unknown.rawValue, "Unknown"),
            ])
        }
        .task { await load() }
        .onChange(of: selection) { newValue in
            guard loaded, newValue != StrapPlacement.unknown.rawValue else { return }
            Task { await save(raw: newValue) }
        }
    }

    private func load() async {
        guard let store = await model.repo.storeHandle(),
              let placementStore = try? PlacementStore(dbQueue: store.registryWriter) else { return }
        let active = (try? placementStore.activePlacement(at: Date(), deviceId: model.repo.deviceId))?.placement
        selection = (active ?? .unknown).rawValue
        loaded = true
    }

    private func save(raw: String) async {
        guard let placement = StrapPlacement(rawValue: raw) else { return }
        guard let store = await model.repo.storeHandle(),
              let placementStore = try? PlacementStore(dbQueue: store.registryWriter) else { return }
        try? placementStore.setCurrent(placement, deviceId: model.repo.deviceId)
        // Best-effort upload of the journal; the edge route is the parent integration point
        // (see docs/core-plumbing/findings/g34-wear-placement.md). A failure leaves the rows
        // unsynced and the next save/launch retries them.
        guard CloudPushSettings.isEnabled, CloudPushIdentityStore.current() != nil else { return }
        let sync = PlacementCloudSync(store: { placementStore })
        _ = try? await sync.pushPending()
        // Pull the server state back after the push so a server-side correction (e.g. a
        // future-dated cap) reaches this install. Best-effort; pending rows block the pull.
        _ = try? await sync.reconcile()
    }
}
