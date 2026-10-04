import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Pair & connect
//
// Settings → Device → Pair & connect. One page for everything about the strap's Bluetooth link: what state it
// is in, and the six things a person might need to do about it (connect, disconnect, buzz, restart, re-pair,
// pair a different strap). Every decision about wording and which button is live comes from
// `StrapConnectionStatus`; this file only lays it out and wires the buttons to `AppModel`.

struct StrapConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue

    /// Set when the user asks for a connection, cleared once a link is up or they stop it. The BLE layer scans
    /// until it finds the strap and has no "searching" state to read, so this page tracks it itself.
    @State private var searchStartedAt: Date?
    @State private var searchIsSlow = false
    /// The last thing the person did was Disconnect, so the page can say the silence is on purpose.
    @State private var userDisconnected = false
    @State private var buzzSentAt: Date?
    /// Armed when a restart is sent, disarmed the moment the link drops (the strap acted on it).
    @State private var restartCheckAt: Date?
    @State private var restartIgnored = false
    @State private var confirmingRestart = false
    @State private var showingRepair = false
    @State private var showingAddStrap = false

    private static let slowSearchSeconds: UInt64 = 20
    private static let buzzNoteSeconds: UInt64 = 4
    /// Longer than the BLE layer's 12 s no-disconnect watchdog, so a strap that is merely finishing a
    /// transfer before it reboots is not reported as having ignored the command.
    private static let restartCheckSeconds: UInt64 = 15

    private var status: StrapConnectionStatus {
        .current(live: live, model: model, searching: searchStartedAt != nil, searchIsSlow: searchIsSlow,
                 userDisconnected: userDisconnected)
    }

    private var strapModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    var body: some View {
        let current = status
        return ScreenScaffold(title: "Pair & connect",
                              subtitle: "Connect, test and re-pair your WHOOP strap.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                statusCard(current)
                connectionGroup(current)
                strapGroup(current)
                pairingGroup(current)
            }
        }
        .alert("Restart your strap?", isPresented: $confirmingRestart) {
            Button("Cancel", role: .cancel) { }
            Button("Restart") { restartStrap() }
        } message: {
            Text("It disconnects for about 30 seconds while it restarts, then reconnects on its own. Your recorded data is kept.")
        }
        .sheet(isPresented: $showingRepair) {
            StrapRepairSheet(searchStartedAt: $searchStartedAt, searchIsSlow: $searchIsSlow) {
                showingRepair = false
            }
            .environmentObject(model)
            .environmentObject(live)
        }
        .sheet(isPresented: $showingAddStrap) {
            AddDeviceWizard(live: live) { showingAddStrap = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        .onChange(of: live.connected) { connected in
            if connected {
                endSearch()
                userDisconnected = false
            } else {
                restartCheckAt = nil
                restartIgnored = false
            }
        }
        .task(id: searchStartedAt) {
            guard let started = searchStartedAt else { return }
            try? await Task.sleep(nanoseconds: Self.slowSearchSeconds * 1_000_000_000)
            if !Task.isCancelled, searchStartedAt == started { searchIsSlow = true }
        }
        .task(id: buzzSentAt) {
            guard let sent = buzzSentAt else { return }
            try? await Task.sleep(nanoseconds: Self.buzzNoteSeconds * 1_000_000_000)
            if !Task.isCancelled, buzzSentAt == sent { buzzSentAt = nil }
        }
        .task(id: restartCheckAt) {
            guard let requested = restartCheckAt else { return }
            try? await Task.sleep(nanoseconds: Self.restartCheckSeconds * 1_000_000_000)
            guard !Task.isCancelled, restartCheckAt == requested else { return }
            restartIgnored = live.connected && !live.rebootInProgress
            restartCheckAt = nil
        }
    }

    // MARK: Status

    private func statusCard(_ status: StrapConnectionStatus) -> some View {
        StrandCard(padding: NoopMetrics.space4) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    StatePill("\(status.title)", tone: status.tone, pulsing: status.isBusy)
                    batteryPill
                    Spacer(minLength: 0)
                }
                if showsModelPicker(status) {
                    modelPicker
                } else {
                    Text(strapSummary)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(status.detail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let leadTitle = status.leadTitle {
                    NoopButton("\(leadTitle)", systemImage: leadSymbol(status.lead), fullWidth: true) {
                        performLead(status.lead)
                    }
                }
            }
        }
    }

    /// Which strap family to look for. Only offered while nothing is connected or in flight, because
    /// switching drops the current strap's bond so the new family pairs fresh.
    private func showsModelPicker(_ status: StrapConnectionStatus) -> Bool {
        switch status.phase {
        case .disconnected, .unpaired, .needsRepair: return true
        default: return false
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Strap model")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            SegmentedPillControl(
                WhoopModel.allCases,
                selection: Binding(
                    get: { strapModel },
                    set: { picked in
                        guard picked.rawValue != selectedModelRaw else { return }
                        selectedModelRaw = picked.rawValue
                        endSearch()
                        model.prepareStrapSwitch()
                    }
                ),
                adaptsToAvailableWidth: true,
                label: { $0.displayName }
            )
        }
    }

    /// "WHOOP 5.0 / MG · Firmware 50.40.1.0" while a link is up, just the model otherwise.
    private var strapSummary: String {
        guard live.connected, let firmware = live.strapFirmware, !firmware.isEmpty else {
            return strapModel.displayName
        }
        return strapModel.displayName + " · " + String(localized: "Firmware \(firmware)")
    }

    @ViewBuilder private var batteryPill: some View {
        if let pct = live.batteryPct {
            let rounded = Int(pct.rounded())
            if !live.connected {
                StatePill("Last battery \(rounded)%", tone: batteryTone(pct), showsDot: false)
            } else if live.charging == true {
                StatePill("Battery \(rounded)% · Charging", tone: batteryTone(pct), showsDot: false)
            } else {
                StatePill("Battery \(rounded)%", tone: batteryTone(pct), showsDot: false)
            }
        }
    }

    private func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    private func leadSymbol(_ lead: StrapConnectionStatus.LeadAction?) -> String? {
        switch lead {
        case .connect: return "arrow.clockwise"
        case .findStrap: return "magnifyingglass"
        case .repair: return "link"
        case nil: return nil
        }
    }

    private func performLead(_ lead: StrapConnectionStatus.LeadAction?) {
        switch lead {
        case .connect, .findStrap: connect()
        case .repair: showingRepair = true
        case nil: break
        }
    }

    // MARK: Groups

    private func connectionGroup(_ status: StrapConnectionStatus) -> some View {
        SettingsGroup("Connection") {
            StrapActionRow(symbol: "arrow.clockwise",
                           title: status.reconnectTitle,
                           detail: status.reconnect.reason ?? reconnectHint(status),
                           isEnabled: status.reconnect.isAvailable,
                           isBusy: status.phase == .searching,
                           action: connect)
            SettingsDivider()
            StrapActionRow(symbol: "xmark.circle",
                           title: status.disconnectTitle,
                           detail: status.disconnect.reason ?? disconnectHint(status),
                           isEnabled: status.disconnect.isAvailable,
                           action: disconnect)
        }
    }

    private func strapGroup(_ status: StrapConnectionStatus) -> some View {
        SettingsGroup("Strap") {
            StrapActionRow(symbol: "waveform",
                           title: String(localized: "Buzz strap"),
                           detail: buzzHint(status),
                           isEnabled: status.buzz.isAvailable,
                           action: buzz)
            SettingsDivider()
            StrapActionRow(symbol: "power",
                           title: String(localized: "Restart strap"),
                           detail: restartHint(status),
                           isEnabled: status.restart.isAvailable) {
                confirmingRestart = true
            }
        }
    }

    private func pairingGroup(_ status: StrapConnectionStatus) -> some View {
        SettingsGroup("Pairing", footer: "None of these actions delete your recorded data.") {
            StrapActionRow(symbol: "link",
                           title: String(localized: "Re-pair strap"),
                           detail: status.pairing.reason
                               ?? String(localized: "Guided fix for a strap that won't connect, drops right away or isn't fully paired."),
                           isEnabled: status.pairing.isAvailable) {
                showingRepair = true
            }
            SettingsDivider()
            StrapActionRow(symbol: "plus.circle",
                           title: String(localized: "Pair a different strap"),
                           detail: status.pairing.reason
                               ?? String(localized: "Add another WHOOP or a heart-rate strap."),
                           isEnabled: status.pairing.isAvailable) {
                showingAddStrap = true
            }
        }
    }

    private func reconnectHint(_ status: StrapConnectionStatus) -> String {
        if status.phase == .searching { return String(localized: "Looking for your strap…") }
        return status.connected
            ? String(localized: "Drops the Bluetooth link and connects again. Try this first when data stops flowing.")
            : String(localized: "Looks for your strap and connects to it.")
    }

    private func disconnectHint(_ status: StrapConnectionStatus) -> String {
        status.phase == .searching
            ? String(localized: "Cancels the search.")
            : String(localized: "Ends the Bluetooth link. Nara stays quiet until you tap Connect.")
    }

    private func buzzHint(_ status: StrapConnectionStatus) -> String {
        if let reason = status.buzz.reason { return reason }
        if buzzSentAt != nil { return String(localized: "Buzz sent. You should feel it on your wrist.") }
        return String(localized: "Vibrates the strap once so you know it's the right one.")
    }

    private func restartHint(_ status: StrapConnectionStatus) -> String {
        if let reason = status.restart.reason { return reason }
        if restartIgnored {
            return String(localized: "The strap didn't restart. Try again, or use Re-pair strap if it keeps happening.")
        }
        return String(localized: "Reboots the strap. It reconnects by itself in about 30 seconds and keeps your data.")
    }

    // MARK: Actions

    private func connect() {
        userDisconnected = false
        searchStartedAt = Date()
        searchIsSlow = false
        model.reconnectStrap()
    }

    private func disconnect() {
        endSearch()
        userDisconnected = true
        model.disconnect()
    }

    private func endSearch() {
        searchStartedAt = nil
        searchIsSlow = false
    }

    private func buzz() {
        model.buzzStrapOnce()
        buzzSentAt = Date()
    }

    private func restartStrap() {
        restartIgnored = false
        model.rebootStrap()
        restartCheckAt = Date()
    }
}

// MARK: - Live status adapter

extension StrapConnectionStatus {
    /// Reads the live link into the plain-value model. The radio message is the one `BLEManager` sets for
    /// Bluetooth off / not allowed / unsupported; no other sync error mentions Bluetooth.
    @MainActor
    static func current(live: LiveState, model: AppModel, searching: Bool, searchIsSlow: Bool,
                        userDisconnected: Bool = false) -> StrapConnectionStatus {
        let registeredWhoop = model.deviceRegistry?.devices.contains {
            SourceCoordinator.isWhoop($0) && $0.status != .archived
        } ?? false
        let rememberedStrap = UserDefaults.standard.string(forKey: BLEManager.lastConnectedPeripheralKey) != nil
        var knownStrap = registeredWhoop || rememberedStrap
        #if DEBUG
        if let forced = StrapDemoSeed.knownStrapOverride { knownStrap = forced }
        #endif
        // The BLE layer only learns a model change on its next scan, so until a link is up the model the person
        // picked is the one that matters; once connected, what the radio is talking to is.
        let chosenModel = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            .flatMap(WhoopModel.init(rawValue:)) ?? .whoop4
        return StrapConnectionStatus(
            connected: live.connected,
            bonded: live.bonded,
            encryptedBond: live.encryptedBond,
            restarting: live.rebootInProgress,
            searching: searching,
            searchIsSlow: searchIsSlow,
            knownStrap: knownStrap,
            pairingHint: live.pairingHint,
            hasReconnectGuide: live.reconnectGuide != nil,
            radioProblem: live.lastSyncError.flatMap { $0.contains("Bluetooth") ? $0 : nil },
            isWhoop4: live.connected ? model.ble.isWhoop4 : chosenModel == .whoop4,
            batteryPct: live.batteryPct,
            userDisconnected: userDisconnected)
    }
}

// MARK: - Action row

/// One tappable action: an icon tile, a title, and a line that either says what it does or, when the action
/// is unavailable, why. The reason stays at full contrast so a greyed-out row never leaves anyone guessing.
private struct StrapActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isEnabled: Bool
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint.opacity(0.14))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.body)
                        .foregroundStyle(isEnabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(isEnabled ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                if isBusy {
                    ProgressView().controlSize(.small).tint(StrandPalette.accent)
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowStyle())
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color { isEnabled ? StrandPalette.accent : StrandPalette.textTertiary }
}

// MARK: - Re-pair guide

/// The guided re-pair: the same four steps the connection-loop banner describes, as buttons and a live
/// result instead of a paragraph to follow by hand. Releasing the strap and searching again are the two
/// steps the app can do itself; clearing the phone's old pairing and the strap's pairing mode are
/// manual, so they are spelled out.
private struct StrapRepairSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @Binding var searchStartedAt: Date?
    @Binding var searchIsSlow: Bool
    let onClose: () -> Void

    @State private var released: Bool
    @State private var startedPairing: Bool

    /// `released` and `startedPairing` only exist so a screenshot can open the guide part-way through.
    init(searchStartedAt: Binding<Date?>, searchIsSlow: Binding<Bool>,
         released: Bool = false, startedPairing: Bool = false,
         onClose: @escaping () -> Void) {
        _searchStartedAt = searchStartedAt
        _searchIsSlow = searchIsSlow
        _released = State(initialValue: released)
        _startedPairing = State(initialValue: startedPairing)
        self.onClose = onClose
    }

    private var status: StrapConnectionStatus {
        .current(live: live, model: model, searching: searchStartedAt != nil, searchIsSlow: searchIsSlow)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text("Use this when your strap won't connect, drops right away, or says it isn't fully paired. Your recorded data isn't touched.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    releaseStep
                    forgetStep
                    pairingModeStep
                    pairStep
                }
                .padding(NoopMetrics.space5)
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    private var header: some View {
        HStack {
            Text("Re-pair your strap")
                .font(StrandFont.rounded(22))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, NoopMetrics.space5)
        .padding(.vertical, NoopMetrics.space4)
    }

    // MARK: Steps

    private var releaseStep: some View {
        RepairStep(number: 1, title: String(localized: "Let go of the strap"), done: released) {
            if released {
                StepText("Released. Nara has stopped reconnecting, so the strap is free to pair again.")
            } else {
                StepText("Nara drops the link and stops reconnecting, so the strap can be paired from scratch.")
                NoopButton("Release strap", systemImage: "xmark.circle", fullWidth: true) {
                    released = true
                    searchStartedAt = nil
                    searchIsSlow = false
                    model.releaseStrapForRepair()
                }
            }
        }
    }

    private var forgetStep: some View {
        RepairStep(number: 2, title: String(localized: "Clear the old pairing")) {
            StepText("Fully close the official WHOOP app by swiping it away. A WHOOP 5.0 / MG only talks to one app at a time.")
            #if os(iOS)
            StepText("Open iPhone Settings → Bluetooth. If your WHOOP is listed, tap the ⓘ next to it and choose Forget This Device.")
            #else
            StepText("Open System Settings → Bluetooth. If your WHOOP is listed, remove it.")
            #endif
        }
    }

    private var pairingModeStep: some View {
        RepairStep(number: 3, title: String(localized: "Put the strap in pairing mode")) {
            StepText("Wear the strap, then tap it repeatedly until its lights flash blue. Keep it close to \(Platform.deviceNounPhrase).")
        }
    }

    private var pairStep: some View {
        RepairStep(number: 4, title: String(localized: "Pair"), done: status.phase == .paired && startedPairing) {
            if !released {
                StepText("Release the strap in step 1 first.")
            }
            NoopButton(startedPairing ? "Search again" : "Start pairing",
                       systemImage: "dot.radiowaves.left.and.right",
                       fullWidth: true) {
                startedPairing = true
                searchStartedAt = Date()
                searchIsSlow = false
                model.scan()
            }
            .disabled(!released)
            if startedPairing { result }
        }
    }

    @ViewBuilder private var result: some View {
        let current = status
        if current.phase == .paired {
            StepText("Paired. Your strap is connected and fully paired.")
            NoopButton("Done", fullWidth: true, action: onClose)
        } else {
            StatePill("\(current.title)", tone: current.tone, pulsing: current.isBusy)
            StepText(verbatim: resultDetail(current))
        }
    }

    /// The generic "paired but out of reach" copy is written for the main page. Here the person has just
    /// asked for a fresh pairing, so an empty result means "check the strap", not "tap Connect".
    private func resultDetail(_ status: StrapConnectionStatus) -> String {
        let nothingFound: [StrapConnectionStatus.Phase] = [.disconnected, .unpaired, .needsRepair]
        if nothingFound.contains(status.phase) && status.radioProblem == nil {
            return String(localized: "Nothing found yet. Check that the strap's lights are flashing blue and it's close to \(Platform.deviceNounPhrase), then search again.")
        }
        return status.detail
    }
}

/// A numbered card in the re-pair guide. The number turns into a tick once the step is done.
private struct RepairStep<Content: View>: View {
    let number: Int
    let title: String
    var done = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: NoopMetrics.space4) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                badge
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    content()
                }
            }
        }
    }

    private var badge: some View {
        let tint = done ? StrandPalette.statusPositive : StrandPalette.accent
        return ZStack {
            Circle().fill(tint.opacity(0.16))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Text("\(number)")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

private struct StepText: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim string: String) { text = Text(verbatim: string) }

    var body: some View {
        text
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
// MARK: - Screenshot harness

/// DEBUG-only. Seeds the live link from `--demo-strap-state <name>` so each state of the Pair & connect page can
/// be captured in a simulator that has no strap. Stripped from Release.
enum StrapDemoSeed {
    static var requestedState: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-strap-state"), i + 1 < args.count else { return "paired" }
        return args[i + 1].lowercased()
    }

    /// The simulator's registry and defaults may remember a strap from an earlier run; `unpaired` has to ignore that.
    @MainActor static var knownStrapOverride: Bool?

    @MainActor
    static func apply(_ state: String, to live: LiveState) {
        knownStrapOverride = state == "unpaired" ? false : nil
        live.connected = false
        live.bonded = false
        live.encryptedBond = false
        live.rebootInProgress = false
        live.pairingHint = nil
        live.reconnectGuide = nil
        live.lastSyncError = nil
        live.charging = false
        live.strapFirmware = nil
        live.batteryPct = 82
        switch state {
        case "paired":
            live.connected = true; live.bonded = true; live.encryptedBond = true
            live.strapFirmware = "50.40.1.0"
        case "partial":
            live.connected = true; live.bonded = true
        case "hint":
            live.connected = true; live.bonded = true
            live.pairingHint = "NOOP can see your strap but it's refusing to pair - it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in NOOP."
        case "connecting":
            live.connected = true
        case "disconnected":
            live.bonded = true
            live.batteryPct = 12
        case "unpaired":
            live.batteryPct = nil
        case "repair":
            live.bonded = true
            live.reconnectGuide = "guide"
        case "restarting":
            live.connected = true; live.bonded = true; live.encryptedBond = true
            live.rebootInProgress = true
        case "radio":
            live.bonded = true
            live.lastSyncError = "Bluetooth is off. Turn it on to connect to your strap."
        default:
            break
        }
    }
}

/// `--demo-screen strap`: the page itself.
struct StrapConnectionDemoScreen: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        StrapConnectionView()
            .task {
                // BLEManager reports the simulator's missing radio shortly after launch; seed again once it has.
                for _ in 0..<3 {
                    StrapDemoSeed.apply(StrapDemoSeed.requestedState, to: live)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
    }
}

/// `--demo-screen straprepair`: the re-pair guide, part-way through when `--demo-repair-step` says so
/// (`start`, `released`, `searching`, `nothing`, `paired`).
struct StrapRepairDemoScreen: View {
    @EnvironmentObject private var live: LiveState

    private var step: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-repair-step"), i + 1 < args.count else { return "start" }
        return args[i + 1].lowercased()
    }

    var body: some View {
        let step = step
        return StrapRepairSheet(searchStartedAt: .constant(step == "searching" ? Date() : nil),
                                searchIsSlow: .constant(false),
                                released: step != "start",
                                startedPairing: ["searching", "nothing", "paired"].contains(step)) { }
            .task {
                for _ in 0..<3 {
                    StrapDemoSeed.apply(step == "paired" ? "paired" : "disconnected", to: live)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
    }
}
#endif
