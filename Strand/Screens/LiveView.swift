import SwiftUI
#if os(macOS)
import AppKit
#endif
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// Live — the connected strap in real time: one status row (which opens the connection details), the one
/// action the current state needs, the live heart rate with its trace, and the session controls. Raw BLE
/// diagnostics, the strap log and the per-signal trust readings live one tap down in
/// `LiveConnectionDetailsView`.
///
/// LiveState (which publishes at ~1 Hz while a strap streams) is observed in leaf views (`LiveStatusRow`,
/// `LiveHeartPanel`, `ActiveWorkoutLive`, and on the details page `LiveSignalRows`, `LiveRRStrip`,
/// `LiveLogCard`) so a fresh HR / R-R / frame notify re-renders that leaf; the parent reads only the coarse
/// connection transitions it needs to re-arm the stream and gate the layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Cross-screen navigation — drives the "Devices" affordance to the first-class Devices manager (where
    /// bands are paired / switched). The shell (sidebar on macOS, a sheet on iOS) routes the request;
    /// LiveView never needs to know which.
    @EnvironmentObject private var router: NavRouter

    /// Which strap the user is pairing — persists across launches. Drives which BLE service we scan for.
    /// WHOOP 5.0/MG is the only WHOOP model (4.0 was retired), so this always resolves to it.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop5mg.rawValue
    private var selectedModel: WhoopModel { WhoopModel.resolve(selectedModelRaw) }

    /// Maps the picked strap model to the HRV-reading source so the spot caveat is honest (#537): a
    /// WHOOP 5/MG's R-R is optical PPG (noisier than a chest strap's electrical R-R). Mirrors the Android
    /// `LiveScreen` mapping.
    private var hrvSnapshotSource: SpotHrvReading.Source { .opticalPPG }

    /// Effort display scale (#268) — routes the live + saved workout Effort read-outs. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Whether the ACTIVE registry device is a WHOOP, resolved once and handed to the leaves.
    private var activeIsWhoop: Bool {
        LiveConsoleReadout.activeIsWhoop(
            devices: model.deviceRegistry?.devices ?? [],
            activeId: model.deviceRegistry?.activeDeviceId,
        )
    }

    /// Whether the ACTIVE registry device is an Oura ring (#2305) — the ring-only affordances below.
    private var activeIsOura: Bool {
        LiveConsoleReadout.activeIsOura(
            devices: model.deviceRegistry?.devices ?? [],
            activeId: model.deviceRegistry?.activeDeviceId,
        )
    }

    /// The live ring's link phase, mirrored off the Oura source (#2305). Meaningful only under
    /// `activeIsOura`; `.disconnected` otherwise.
    private var ringPhase: OuraLiveSource.LinkPhase { model.ouraLinkPhase }

    /// A trusted WHOOP link, for the console readouts and the bond-only controls.
    ///
    /// Gated on the active device actually BEING a WHOOP (#2075). `LiveState` is one object that every
    /// live source writes into, so `connected && bonded` stays true for a bonded strap while an Oura
    /// ring is the device on screen. That showed the WHOOP pill, the WHOOP charge and live WHOOP-only
    /// controls under the ring's name, and made the pill's own ring branch unreachable, because this one
    /// is tested first.
    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }

    /// The display name of the active device from the registry ("WHOOP", a strap's nickname, …) — what
    /// the user is connected to, or would connect to. Falls back to "WHOOP" before the registry opens or
    /// when none is resolvable, keeping the WHOOP-first tone. Drives the active-device readout + copy.
    private var activeDeviceName: String {
        guard let registry = model.deviceRegistry,
              let active = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        else { return "WHOOP" }
        return active.displayName
    }

    /// Live workout mode (#238) — presents the full in-exercise screen while a manual workout is
    /// active. Auto-opens when a workout begins; closing just hides it (the workout keeps recording).
    @State private var showLiveWorkout = false
    @State private var showStartSport = false
    @State private var confirmingEndWorkout = false

    /// Manual HRV snapshot (#127) — presents the "Take an HRV reading" screen as a sheet. Entry sits in
    /// the session controls and is only enabled while bonded (the reading needs the live R-R stream).
    @State private var showHRVSnapshot = false

    var body: some View {
        ScreenScaffold(title: "Live") {
            statusCard
            // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
            // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
            // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
            if let guide = live.reconnectGuide {
                InlineNotice(guide, title: String(localized: "Can't connect: your strap's pairing was reset"),
                             tone: .warning)
                    .accessibilityLabel("Reconnect help: \(guide)")
            }
            // Bond-refused guidance, shown right here on Live where people actually connect (it
            // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
            // with "Encryption is insufficient" — this tells the user to free it and re-pair.
            if let hint = live.pairingHint {
                InlineNotice(hint, title: String(localized: "Live HR works. Free the strap to unlock buzz, alarms & sync"),
                             tone: .warning)
                    .accessibilityLabel("Pairing help: \(hint)")
            }
            // The one action the link needs, once. WHOOP only for Scan (#2305): under a ring this ran a WHOOP
            // scan. The ring gets its own reconnect until `auth OK`. Gated purely on the link, so it
            // disappears the instant the radio connects.
            if activeIsWhoop, !live.connected {
                scanButton
            } else if activeIsOura, ringPhase != .authenticated {
                ringReconnectButton
            }
            LiveHeartPanel(activeIsWhoop: activeIsWhoop, activeIsOura: activeIsOura)
            sessionControls
        }
        .onAppear { refreshLiveSession(); consumeActiveWorkoutRequest() }
        .onDisappear { model.stopRealtimeHR() }
        // A fresh bond/connection re-arms the BLE stream (Apple must re-send startRealtime on a new
        // connection) WITHOUT bumping the ref-count — `refreshLiveSession`'s `startRealtimeHR` already
        // counted this screen once on `.onAppear`, balanced by the single `stopRealtimeHR` above.
        // Re-counting here (multiple bonded/connected events per appearance, one disappear) would leave
        // the stream stuck armed after leaving Live (#681 ref-count balance).
        .onChangeCompat(of: live.bonded) { _ in reconnectLiveSession() }
        .onChangeCompat(of: live.connected) { _ in reconnectLiveSession() }
        // Live workout mode (#238): open the in-exercise screen the moment a workout starts.
        .onChangeCompat(of: model.activeWorkout != nil) { active in if active { showLiveWorkout = true } }
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model)
                .environmentObject(live)
        }
        // Pick a named sport before starting (#519) — the live workout view then opens
        // off the activeWorkout change above, so no extra navigation is needed here.
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in model.startWorkout(sport: name) }
        }
        // Manual HRV snapshot (#127) — a still, seated 60s R-R reading.
        .sheet(isPresented: $showHRVSnapshot) {
            // Tell the reading where its R-R is coming from so the caveat is honest (#537): a WHOOP 5/MG
            // derives R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is
            // electrical R-R. Driven off the picked strap model, mirroring the Android twin.
            HRVSnapshotView(onClose: { showHRVSnapshot = false }, source: hrvSnapshotSource)
                .environmentObject(model)
                .environmentObject(live)
        }
        .alert("End this workout?", isPresented: $confirmingEndWorkout) {
            Button("Cancel", role: .cancel) { }
            Button("End workout", role: .destructive) {
                model.endWorkout()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
    }

    // MARK: - Status

    /// The device, its state in a word and its charge, in one row that opens the connection details.
    private var statusCard: some View {
        NavigationLink {
            LiveConnectionDetailsView(activeIsWhoop: activeIsWhoop, activeIsOura: activeIsOura,
                                      deviceName: activeDeviceName, selectedModel: selectedModel)
        } label: {
            NoopCard(padding: 0) {
                LiveStatusRow(activeIsWhoop: activeIsWhoop, activeIsOura: activeIsOura, deviceName: activeDeviceName)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the connection details")
    }

    // MARK: - Session controls

    @ViewBuilder private var sessionControls: some View {
        if let w = model.activeWorkout {
            activeWorkoutCard(w)
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // Two full-width buttons side by side, stacked when a large text size cannot fit them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NoopMetrics.gap) { startWorkoutButton; hrvReadingButton }
                    VStack(spacing: NoopMetrics.gap) { startWorkoutButton; hrvReadingButton }
                }
                if !activeConnection {
                    // `.help` is a Mac tooltip: on iPhone the disabled buttons need their reason on screen.
                    Text("Connect your strap to start a workout or take an HRV reading.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let last = model.lastWorkout {
                    workoutSavedRow(last)
                }
            }
        }
    }

    private var startWorkoutButton: some View {
        NoopButton("Start workout", systemImage: "figure.run", kind: .primary, fullWidth: true) {
            showStartSport = true
        }
        .disabled(!activeConnection)
        .help("Track a workout manually. Records heart rate and effort until you end it.")
    }

    /// Manual HRV snapshot (#127) — a still, seated 60s R-R reading. Needs the live R-R stream, so it's
    /// gated on a bonded connection just like the workout action.
    private var hrvReadingButton: some View {
        NoopButton("HRV reading", systemImage: "waveform.path.ecg", kind: .secondary, fullWidth: true) {
            showHRVSnapshot = true
        }
        .disabled(!activeConnection)
        .help(activeConnection
              ? "Take a 60-second seated HRV reading from the live R-R stream."
              : "Connect your strap first. The reading needs the live R-R stream.")
    }

    private func activeWorkoutCard(_ w: AppModel.ActiveWorkout) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space2) {
                    // "Recording" is a factual claim, and while paused nothing IS being recorded — the
                    // sample capture drops every reading. So the word swaps rather than gaining a tag
                    // beside it, which would leave the card asserting both at once. Reuses the "Paused"
                    // string #1533 already localized.
                    StatePill(w.isPaused ? "Paused" : "Recording workout", tone: w.isPaused ? .neutral : .critical)
                    Spacer()
                    // Re-render once a second so the elapsed clock ticks without a manual Timer.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveWorkoutClock.clock(Int(w.elapsed(at: context.date))))
                            .font(StrandFont.number(20)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                // Live HR / avg / peak / effort — the leaf owns the AppModel read so the 1 Hz stat refresh
                // re-renders only these values.
                ActiveWorkoutLive(workout: w, effortScale: effortScale)
                // Pause/Resume is one toggle (a paused session has exactly one sensible action), and End
                // has its own row so a destructive tap is not adjacent to a routine one.
                HStack(spacing: NoopMetrics.gap) {
                    NoopButton(w.isPaused ? "Resume" : "Pause",
                               systemImage: w.isPaused ? "play.fill" : "pause.fill",
                               kind: .secondary, fullWidth: true) {
                        model.toggleWorkoutPause()
                    }
                    // Re-open the full live workout screen (#238) after it's been dismissed.
                    NoopButton("Open live view", systemImage: "rectangle.expand.vertical",
                               kind: .secondary, fullWidth: true) {
                        showLiveWorkout = true
                    }
                }
                NoopButton("End workout", systemImage: "stop.circle.fill",
                           kind: .destructive, fullWidth: true) {
                    confirmingEndWorkout = true
                }
            }
        }
    }

    private func workoutSavedRow(_ row: WorkoutRow) -> some View {
        let mins = Int((row.durationS ?? 0) / 60)
        let parts = [String(localized: "\(mins) min"), row.avgHr.map { String(localized: "\($0) avg bpm") },
                     row.strain.map { String(localized: "effort \(UnitFormatter.effortDisplay($0, scale: effortScale))") }].compactMap { $0 }
        return HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "checkmark.circle.fill")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.statusPositive)
            Text("Workout saved · \(parts.joined(separator: " · "))")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NoopMetrics.space1)
        .accessibilityElement(children: .combine)
    }

    /// Whether the low-bandwidth standard-HR fallback note should render. The note explains that live HR
    /// is coming over the standard BLE Heart-Rate profile because the radio couldn't sustain the full
    /// stream (#80). Shown only when LiveState carries a non-empty note string; pure so it's unit-testable
    /// without standing up a SwiftUI view. The note itself is on the connection details page.
    static func shouldShowStandardHRNote(_ note: String?) -> Bool {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    // MARK: - Controls

    /// The primary Connect action, shown once, only while there is no WHOOP link.
    private var scanButton: some View {
        NoopButton(live.connected ? "Re-scan" : "Scan & connect",
                   systemImage: "antenna.radiowaves.left.and.right",
                   kind: .primary, fullWidth: true) {
            model.scan(model: selectedModel)
        }
    }

    /// Drops the current ring link, if any, and connects again — `OuraLiveSource.reconnect()` through the
    /// coordinator, so it can only reach the ring that is the live source. Enabled in every phase: a ring
    /// parked in `.authenticating` (#2303) is exactly the case this exists for.
    private var ringReconnectButton: some View {
        NoopButton("Reconnect ring", systemImage: "arrow.clockwise",
                   kind: .primary, fullWidth: true) {
            model.reconnectOuraRing()
        }
    }

    /// Live tab appeared: take a ref-count on the realtime stream (arms it on the 0→1 edge) and pull a
    /// battery reading. Balanced by the single `stopRealtimeHR()` on `.onDisappear`.
    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    /// Honour a one-shot "Return to workout" from the Today indicator card: present the in-exercise screen
    /// for an already-running workout, then clear the flag. The #238 "a workout just started" transition
    /// trigger never fires for a session that is already in flight, so this is the path that re-opens it.
    /// Guarded on a live `activeWorkout` so a stale flag can never present an empty live-workout sheet, and
    /// it sets the SAME `showLiveWorkout` one-shot the manual re-open button uses (no new sheet machinery).
    private func consumeActiveWorkoutRequest() {
        guard router.presentActiveWorkout else { return }
        router.presentActiveWorkout = false
        if model.activeWorkout != nil { showLiveWorkout = true }
    }

    /// A fresh bond/connection landed while the Live tab is up: re-arm the BLE stream (Apple re-sends
    /// startRealtime on a new connection) and refresh battery — WITHOUT taking another ref-count, since
    /// these events can fire several times per appearance against the single `.onDisappear` release.
    private func reconnectLiveSession() {
        guard activeConnection else { return }
        model.rearmRealtimeIfWanted()
        model.getBattery()
    }
}

// MARK: - Live leaves (each owns LiveState so a 1 Hz notify re-renders only the leaf — the Today pattern)

/// The status row: the device, its state in one word (a dot reinforces it, never alone) and, while there is
/// a live link, its charge. Owns LiveState so battery, wear and sync updates re-render only this row.
private struct LiveStatusRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Resolved by the parent (#2075), so the charge below can belong to the device being named.
    let activeIsWhoop: Bool
    let activeIsOura: Bool
    let deviceName: String

    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }
    /// #218: an Oura ring streams live HR WITHOUT a WHOOP bond, so `activeConnection` (which needs the bond)
    /// is false for it. `streamingLiveHR` is Oura-only, so this never widens WHOOP.
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    private var liveLink: Bool { activeConnection || ringStreaming }

    /// The connection in one word. Distinguishes a GENUINE encrypted bond from the 5/MG live-HR shortcut
    /// that flips `bonded` true over the unbonded standard profile (#69). A ring reads its OWN phase
    /// (#2305): `live.connected` is whichever source last wrote it.
    private var state: (word: String, tone: StrandTone) {
        if activeIsOura && !ringStreaming {
            switch model.ouraLinkPhase {
            case .disconnected: return (String(localized: "Offline"), .neutral)
            case .connecting: return (String(localized: "Connecting"), .warning)
            case .authenticating: return (String(localized: "Authenticating"), .warning)
            case .authenticated: return (String(localized: "Connected"), .warning)
            }
        }
        if activeConnection && live.encryptedBond { return (String(localized: "Streaming"), .positive) }
        if activeConnection { return (String(localized: "Live HR only"), .warning) }
        if ringStreaming { return (String(localized: "Streaming"), .positive) }
        if live.connected { return (String(localized: "Connected"), .warning) }
        if live.encryptedBond { return (String(localized: "Paired · idle"), .neutral) }
        return (String(localized: "Offline"), .neutral)
    }

    /// The ACTIVE device's charge (#2075), only while there is a live link: offline it would be a stale
    /// number from the last connection (it moves to the details page, labelled).
    private var batteryLabel: String? {
        guard liveLink else { return nil }
        return LiveConsoleReadout.batteryPercent(
            activeIsWhoop: activeIsWhoop, whoopPct: live.batteryPct, ringPct: live.ouraBatteryPct,
        ).map { "\($0) %" }
    }

    var body: some View {
        let state = self.state
        let subtitle = live.backfilling ? "\(state.word) · \(String(localized: "Syncing history"))" : state.word
        HStack(spacing: NoopMetrics.space3) {
            ConnectionDot(tone: state.tone)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(verbatim: deviceName)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(state.tone == .neutral ? StrandPalette.textSecondary : state.tone.color)
                    .lineLimit(1)
            }
            Spacer(minLength: NoopMetrics.space2)
            if let batteryLabel {
                Label(batteryLabel, systemImage: "battery.75percent")
                    .font(StrandFont.subhead.monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
                    .labelStyle(.titleAndIcon)
            }
            Image(systemName: "chevron.right")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The live heart rate: the value and its zone, and the trace of the last half hour at one sample a
/// second — the one continuously moving thing in the app, because it is a live signal. Owns the AppModel
/// read (`model.bpm`, smoothed and spike-filtered) and the trace buffer, so a new beat re-renders only this
/// card. The buffer is presentation only: one sample of the displayed value per second while it exists,
/// kept for `window` seconds; nothing is stored.
private struct LiveHeartPanel: View {
    let activeIsWhoop: Bool
    let activeIsOura: Bool
    @EnvironmentObject private var model: AppModel

    @State private var trace: [IntradayChart.Sample] = []
    @State private var now = Date()

    /// The trace's span. Half an hour gives the clock axis two or three round labels to stand on.
    private static let window: TimeInterval = 30 * 60
    private static let axis = ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30, clampTo: 30...230))

    private var displayHR: Int? {
        #if DEBUG
        if DemoLiveHeart.requested { return trace.last.map { Int($0.value.rounded()) } }
        #endif
        return model.bpm
    }

    private var zone: Int {
        guard let bpm = displayHR else { return 0 }
        return model.profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
    }

    /// The zones as value bands behind the trace, so where the line sits says which zone it is in.
    private var zoneBands: [IntradayChart.ValueBand] {
        model.profile.hrZoneSet.zones.map { z in
            .init(id: "z\(z.number)", range: z.lower...z.upper, color: StrandPalette.hrZoneColor(z.number),
                  label: "Z\(z.number)")
        }
    }

    var body: some View {
        let window = now.addingTimeInterval(-Self.window)...now
        let zoneRange = model.profile.hrZoneSet.zones.first { $0.number == zone }
        let content = ReadoutContent(
            dateLine: displayHR == nil ? "" : ReadoutContent.dateLine(now, period: .time),
            value: displayHR.map(String.init), unit: "bpm",
            context: zone >= 1 ? zoneRange.map { String(localized: "Zone \(zone) · \(Int($0.lower))–\(Int($0.upper)) bpm") }
                                 ?? String(localized: "Zone \(zone)")
                               : nil)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                ValueReadout(content, isScrubbing: displayHR != nil)
                IntradayChart(samples: trace, bucketSeconds: 3, valueBands: zoneBands, live: true, legend: [],
                              state: trace.isEmpty ? .empty(String(localized: "No heart rate yet")) : .ready,
                              window: window, y: Self.axis, selection: .constant(nil),
                              height: NoopMetrics.chartHeightSecondary,
                              accessibilityTitle: String(localized: "Live heart rate"))
                    .naraChartScrubDisabled()
            }
        }
        .task { await sample() }
    }

    /// One sample a second for as long as the card is on screen; cancelled with it.
    private func sample() async {
        #if DEBUG
        if DemoLiveHeart.requested, trace.isEmpty { trace = DemoLiveHeart.history(endingAt: Date(), span: Self.window) }
        #endif
        while !Task.isCancelled {
            let tick = Date()
            now = tick
            var next = trace.filter { $0.time >= tick.addingTimeInterval(-Self.window) }
            #if DEBUG
            if DemoLiveHeart.requested { next.append(DemoLiveHeart.sample(at: tick)) }
            #endif
            if let bpm = model.bpm { next.append(.init(time: tick, value: Double(bpm))) }
            trace = next
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// The active-workout live stats (HR / avg / peak / effort). Owns the AppModel read so the 1 Hz HR/effort
/// refresh re-renders only this block.
private struct ActiveWorkoutLive: View {
    @EnvironmentObject private var model: AppModel
    let workout: AppModel.ActiveWorkout
    let effortScale: EffortScale

    var body: some View {
        HStack(alignment: .top, spacing: NoopMetrics.gap) {
            stat(String(localized: "Heart rate"), model.bpm.map { "\($0)" }, unit: "bpm")
            stat(String(localized: "Avg"), workout.avgHr > 0 ? "\(workout.avgHr)" : nil, unit: "bpm")
            stat(String(localized: "Peak"), workout.peakHr > 0 ? "\(workout.peakHr)" : nil, unit: "bpm")
            stat(String(localized: "Effort"), UnitFormatter.effortDisplay(workout.liveStrain, scale: effortScale), unit: nil)
        }
    }

    private func stat(_ title: String, _ value: String?, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(title).strandLabel().lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                if value != nil, let unit {
                    Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared sync-label formatting

/// The "last sync" relative-time label — shared between the status row and the connection details so both
/// read identically.
enum LiveSyncFormat {
    static func lastSyncLabel(_ ts: TimeInterval?) -> String {
        guard let ts else { return String(localized: "Never") }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#if DEBUG
/// `--demo-live-heart`: a synthetic live trace for simulator screenshots, where no strap can stream. Only
/// the card's own buffer is filled; nothing reaches AppModel or LiveState.
enum DemoLiveHeart {
    static var requested: Bool { CommandLine.arguments.contains("--demo-live-heart") }

    static func sample(at time: Date) -> IntradayChart.Sample {
        let t = time.timeIntervalSince1970
        let value = 96 + 22 * sin(t / 140) + 6 * sin(t / 23) + 3 * sin(t / 7)
        return .init(time: time, value: value.rounded())
    }

    static func history(endingAt end: Date, span: TimeInterval) -> [IntradayChart.Sample] {
        stride(from: span, to: 0, by: -1).map { sample(at: end.addingTimeInterval(-$0)) }
    }
}
#endif

// MARK: - Ring status copy (#2305)

/// One line per ring link phase, shared by the console centrepiece caption, the above-the-fold callout
/// and the controls row so the three never disagree about what the ring is doing.
enum LiveRingCopy {
    static func status(_ phase: OuraLiveSource.LinkPhase, streaming: Bool) -> String {
        switch phase {
        case .disconnected:   return String(localized: "Ring not connected.")
        case .connecting:     return String(localized: "Connecting to the ring…")
        case .authenticating: return String(localized: "Connected, authenticating…")
        case .authenticated:
            return streaming
                ? String(localized: "Live heart rate is flowing from the ring.")
                : String(localized: "Connected, waiting for live heart rate.")
        }
    }
}
