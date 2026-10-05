import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Pair & connect
//
// Settings → Device → Pair & connect. One page for everything about the strap's Bluetooth link: what state it
// is in, and the six things a person might need to do about it (connect, disconnect, buzz, restart, re-pair,
// pair a different strap). Every decision about wording and which button is live comes from
// `StrapConnectionStatus`; this file only lays it out and wires the buttons to `AppModel`.
//
// The layout is fixed. Connecting, dropping, searching and pairing change what the page says, never where
// anything sits: see `StableLayout.swift` for how each piece of text gets a slot sized for the most it can say.

/// The entry point. It holds the app-wide objects without watching them: `LiveState` publishes every time a
/// heart-rate sample arrives, and a view that observes it re-runs its body at that rate. The page below is
/// gated on the identity of those objects, and reads the few link values it shows through `StrapLinkObserver`,
/// which only publishes when one of them actually changes.
struct StrapConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        StrapConnectionPage(model: model, live: live).equatable()
    }
}

private struct StrapConnectionPage: View, Equatable {
    let model: AppModel
    let live: LiveState

    @StateObject private var link: StrapLinkObserver
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop5mg.rawValue

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

    init(model: AppModel, live: LiveState) {
        self.model = model
        self.live = live
        _link = StateObject(wrappedValue: StrapLinkObserver.bound(to: live, model: model))
    }

    static func == (lhs: StrapConnectionPage, rhs: StrapConnectionPage) -> Bool {
        lhs.model === rhs.model && lhs.live === rhs.live
    }

    private var status: StrapConnectionStatus {
        StrapConnectionStatus(link: link.inputs, searching: searchStartedAt != nil, searchIsSlow: searchIsSlow,
                              userDisconnected: userDisconnected)
    }

    private var notes: StrapActionNotes {
        StrapActionNotes(buzzSent: buzzSentAt != nil, restartIgnored: restartIgnored)
    }

    private var strapModel: WhoopModel { WhoopModel.resolve(selectedModelRaw) }

    var body: some View {
        let current = status
        return ScreenScaffold(title: "Pair & connect",
                              subtitle: "Connect, test and re-pair your WHOOP strap.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                StrapStatusCard(status: current,
                                link: link.inputs,
                                selectedModel: strapModel,
                                onPickModel: pickModel,
                                onLead: { performLead(current.lead) })
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
            StrapRepairSheet(model: model, live: live,
                             searchStartedAt: $searchStartedAt, searchIsSlow: $searchIsSlow) {
                showingRepair = false
            }
        }
        .sheet(isPresented: $showingAddStrap) {
            AddDeviceWizard(live: live) { showingAddStrap = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        .onAppear { link.refresh() }
        .onChangeCompat(of: link.inputs.connected) { connected in
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

    // MARK: Status card

    private func pickModel(_ picked: WhoopModel) {
        guard picked.rawValue != selectedModelRaw else { return }
        selectedModelRaw = picked.rawValue
        endSearch()
        model.prepareStrapSwitch()
        link.refresh()
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
            row(.reconnect, symbol: "arrow.clockwise", status, busy: status.phase == .searching, perform: connect)
            SettingsDivider()
            row(.disconnect, symbol: "xmark.circle", status, perform: disconnect)
        }
    }

    private func strapGroup(_ status: StrapConnectionStatus) -> some View {
        SettingsGroup("Strap") {
            row(.buzz, symbol: "waveform", status, perform: buzz)
            SettingsDivider()
            row(.restart, symbol: "power", status) { confirmingRestart = true }
        }
    }

    private func pairingGroup(_ status: StrapConnectionStatus) -> some View {
        SettingsGroup("Pairing", footer: "None of these actions delete your recorded data.") {
            row(.repair, symbol: "link", status) { showingRepair = true }
            SettingsDivider()
            row(.pairDifferent, symbol: "plus.circle", status) { showingAddStrap = true }
        }
    }

    private func row(_ action: StrapAction, symbol: String, _ status: StrapConnectionStatus,
                     busy: Bool? = nil, perform: @escaping () -> Void) -> some View {
        StrapActionRow(symbol: symbol,
                       title: status.title(of: action),
                       detail: status.detail(of: action, notes: notes),
                       possibleDetails: action.possibleDetails,
                       isEnabled: status.availability(of: action).isAvailable,
                       busy: busy,
                       action: perform)
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

// MARK: - Action row

/// One tappable action: an icon tile, a title, and a line that either says what it does or, when the action
/// is unavailable, why. The reason stays at full contrast so a greyed-out row never leaves anyone guessing.
///
/// `possibleDetails` is every line this row can show; the row is as tall as the tallest, so the line changing
/// (a reason appearing, a hint turning into "Buzz sent") does not move the rows below it. `busy` is nil for a
/// row that never shows a spinner, and otherwise keeps the spinner's width whether or not it is spinning, so
/// the text wraps the same either way.
struct StrapActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    var possibleDetails: [String] = []
    let isEnabled: Bool
    var busy: Bool?
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
                        .lineLimit(1)
                    ReservedText(text: detail,
                                 alternatives: possibleDetails,
                                 font: StrandFont.footnote,
                                 color: isEnabled ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                }
                Spacer(minLength: NoopMetrics.space2)
                if let busy {
                    ZStack {
                        if busy { ProgressView().controlSize(.small).tint(StrandPalette.accent) }
                    }
                    .frame(width: 20, height: 20)
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
///
/// Like the page behind it, nothing here changes size as the guide moves along. A step's line and button
/// swap in place, and the result box under "Start pairing" is there from the start (empty until a search is
/// running) so that starting a search, finding the strap and finishing never push the steps above it around.
private struct StrapRepairSheet: View {
    let model: AppModel
    let live: LiveState
    @Binding var searchStartedAt: Date?
    @Binding var searchIsSlow: Bool
    let onClose: () -> Void

    @StateObject private var link: StrapLinkObserver
    @State private var released: Bool
    @State private var startedPairing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let releaseLine = String(localized: "Nara drops the link and stops reconnecting, so the strap can be paired from scratch.")
    private static let releasedLine = String(localized: "Released. Nara has stopped reconnecting, so the strap is free to pair again.")
    private static let releaseFirstLine = String(localized: "Release the strap in step 1 first.")
    private static let readyLine = String(localized: "Ready. Start once the strap's lights are flashing blue.")
    private static let notStartedLine = String(localized: "Once you start, what Nara finds shows up here.")
    private static let pairedLine = String(localized: "Paired. Your strap is connected and fully paired.")

    /// `released` and `startedPairing` only exist so a screenshot can open the guide part-way through.
    init(model: AppModel, live: LiveState,
         searchStartedAt: Binding<Date?>, searchIsSlow: Binding<Bool>,
         released: Bool = false, startedPairing: Bool = false,
         onClose: @escaping () -> Void) {
        self.model = model
        self.live = live
        _searchStartedAt = searchStartedAt
        _searchIsSlow = searchIsSlow
        _released = State(initialValue: released)
        _startedPairing = State(initialValue: startedPairing)
        _link = StateObject(wrappedValue: StrapLinkObserver.bound(to: live, model: model))
        self.onClose = onClose
    }

    private var status: StrapConnectionStatus {
        StrapConnectionStatus(link: link.inputs, searching: searchStartedAt != nil, searchIsSlow: searchIsSlow)
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
        .onAppear { link.refresh() }
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
            ReservedText(text: released ? Self.releasedLine : Self.releaseLine,
                         alternatives: [Self.releaseLine, Self.releasedLine])
            NoopButton(released ? "Released" : "Release strap",
                       systemImage: released ? "checkmark" : "xmark.circle",
                       fullWidth: true) {
                released = true
                searchStartedAt = nil
                searchIsSlow = false
                model.releaseStrapForRepair()
            }
            .disabled(released)
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
        let current = status
        return RepairStep(number: 4, title: String(localized: "Pair"), done: current.phase == .paired && startedPairing) {
            ReservedText(text: released ? Self.readyLine : Self.releaseFirstLine,
                         alternatives: [Self.readyLine, Self.releaseFirstLine])
            NoopButton(startedPairing ? "Search again" : "Start pairing",
                       systemImage: "dot.radiowaves.left.and.right",
                       fullWidth: true) {
                startedPairing = true
                searchStartedAt = Date()
                searchIsSlow = false
                model.scan()
            }
            .disabled(!released)
            result(current)
        }
    }

    /// The outcome of the search, in a box that is always there and always the same size.
    private func result(_ current: StrapConnectionStatus) -> some View {
        let finished = startedPairing && current.phase == .paired
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Group {
                    if startedPairing {
                        StatePill("\(current.title)", tone: current.tone, pulsing: current.isBusy)
                            .id(current.phase)
                    } else {
                        StatePill("Not started yet", tone: .neutral, showsDot: false)
                    }
                }
                .lineLimit(1)
                .transition(.opacity)
                Spacer(minLength: 0)
            }
            FixedMessageArea(text: resultMessage(current), lines: 3)
            NoopButton("Done", fullWidth: true, action: onClose)
                .hidden()
                .accessibilityHidden(true)
                .overlay {
                    if finished {
                        NoopButton("Done", fullWidth: true, action: onClose)
                            .transition(.opacity)
                    }
                }
        }
        .animation(reduceMotion ? nil : PairingMotion.settle, value: startedPairing ? current.phase : nil)
    }

    private func resultMessage(_ current: StrapConnectionStatus) -> String {
        guard startedPairing else { return Self.notStartedLine }
        if current.phase == .paired { return Self.pairedLine }
        return resultDetail(current)
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

/// `--demo-screen strap`: the page itself. With `--demo-strap-cycle` it walks through every state, a couple of
/// seconds apart, so the layout can be filmed or inspected as the strap connects, drops and pairs.
struct StrapConnectionDemoScreen: View {
    @EnvironmentObject private var live: LiveState

    private static let cycle = ["unpaired", "disconnected", "connecting", "partial", "hint", "paired",
                                "restarting", "repair", "radio", "paired"]

    var body: some View {
        StrapConnectionView()
            .task {
                if CommandLine.arguments.contains("--demo-strap-cycle") {
                    for state in Self.cycle {
                        StrapDemoSeed.apply(state, to: live)
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                    }
                    return
                }
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
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    private var step: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-repair-step"), i + 1 < args.count else { return "start" }
        return args[i + 1].lowercased()
    }

    var body: some View {
        let step = step
        return StrapRepairSheet(model: model, live: live,
                                searchStartedAt: .constant(step == "searching" ? Date() : nil),
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
