import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import OuraProtocol

// MARK: - Live: connection details
//
// One tap down from the Live screen's status row: everything that says how current and how trustworthy the
// stream is, and the strap's own controls. Each signal is a row (value and one line of detail), the recent
// R-R intervals a small bar strip, then Buzz / Refresh / Re-scan / Disconnect, the ring's reconnect, the strap
// log with its export, and the rows to Devices and the Test Centre. The leaves own LiveState, as on the Live
// screen, so a 1 Hz notify re-renders a leaf rather than the page.

struct LiveConnectionDetailsView: View {
    let activeIsWhoop: Bool
    let activeIsOura: Bool
    let deviceName: String
    let selectedModel: WhoopModel

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var router: NavRouter

    /// A trusted WHOOP link (the same gate as `LiveView.activeConnection`, #2075).
    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }
    /// A non-WHOOP live source (the Oura ring) that is connected and streaming live HR (#69 twin).
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    private var ringPhase: OuraLiveSource.LinkPhase { model.ouraLinkPhase }

    var body: some View {
        ScreenScaffold(title: "Connection details", titleDisplay: .navigationBar) {
            LiveSignalRows(activeConnection: activeConnection, activeIsWhoop: activeIsWhoop)
            // Low-bandwidth fallback note (#80): the radio couldn't sustain the full realtime stream, so live
            // HR is riding the standard BLE Heart-Rate profile instead. Live HR still works, so it is
            // informational, not a warning.
            if LiveView.shouldShowStandardHRNote(live.standardHRMode) {
                InlineNotice(live.standardHRMode ?? "", title: String(localized: "Standard HR mode (low bandwidth)"),
                             tone: .accent)
                    .accessibilityLabel("Standard HR mode, low bandwidth. \(live.standardHRMode ?? "")")
            }
            // The 5/MG bonds to one host at a time, so a scan finds nothing while the official app holds it.
            // WHOOP only (#2305).
            if activeIsWhoop, !activeConnection {
                InlineNotice(String(localized: "WHOOP 5.0/MG pairs with one app at a time. If a scan finds nothing, unpair it in the official WHOOP app and fully close that app, then Scan again."),
                             tone: .neutral)
            }
            LiveRRStrip(activeIsWhoop: activeIsWhoop)
            controls
            LiveLogCard()
            NoopListSection {
                Button { router.openDevices() } label: {
                    NoopListRow(icon: "badge.plus.radiowaves.right", title: "Devices", value: deviceName)
                }
                .accessibilityHint("Opens the Devices screen, where you pair and switch bands.")
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                // Users look on Live first when something's wrong (#507/#509), so the Test Centre diagnostic
                // home is one tap from the log.
                NavigationLink(destination: TestCentreView()) {
                    NoopListRow(icon: "testtube.2", title: "Test Centre")
                }
                .accessibilityLabel("Open Test Centre")
            }
            .buttonStyle(.plain)
            AboutDisclosure("About the connection", paragraphs: about)
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        // Scan / Buzz / Disconnect are the WHOOP path (`model.scan` → `BLEManager.connect`, the explicit
        // user-connect that bypasses the #1881 active-device gate on purpose). A ring gets its own reconnect;
        // any other brand keeps the Devices row alone.
        if activeIsWhoop {
            VStack(spacing: NoopMetrics.gap) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NoopMetrics.gap) { buzzButton; refreshButton }
                    VStack(spacing: NoopMetrics.gap) { buzzButton; refreshButton }
                }
                if live.connected {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: NoopMetrics.gap) { rescanButton; disconnectButton }
                        VStack(spacing: NoopMetrics.gap) { rescanButton; disconnectButton }
                    }
                } else {
                    rescanButton
                }
            }
        } else if activeIsOura {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text(LiveRingCopy.status(ringPhase, streaming: ringStreaming))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Drops the current ring link, if any, and connects again (#2303): enabled in every phase.
                NoopButton("Reconnect ring", systemImage: "arrow.clockwise", kind: .secondary, fullWidth: true) {
                    model.reconnectOuraRing()
                }
            }
        }
    }

    private var buzzButton: some View {
        NoopButton("Buzz strap", systemImage: "waveform.path", kind: .secondary, fullWidth: true) {
            // #921: the confirmed one-shot sequence (pattern + RUN_ALARM, acked). A bare pattern
            // write here was the same silent no-buzz path the Siri shortcut hit on a WHOOP 4.0.
            model.buzzStrapOnce()
        }
        .disabled(!activeConnection)
        .help("Fire a test haptic buzz on the strap (requires an active strap connection)")
    }

    private var refreshButton: some View {
        NoopButton("Refresh", systemImage: "arrow.clockwise", kind: .secondary, fullWidth: true) {
            model.getBattery()
        }
        .disabled(!activeConnection)
        .help("Refresh strap battery and connection state.")
    }

    private var rescanButton: some View {
        NoopButton(live.connected ? "Re-scan" : "Scan & connect", systemImage: "antenna.radiowaves.left.and.right",
                   kind: .secondary, fullWidth: true) {
            model.scan(model: selectedModel)
        }
    }

    /// Only offered while there is a link to drop (a disabled destructive slab offline was noise).
    private var disconnectButton: some View {
        NoopButton("Disconnect", systemImage: "xmark.circle", kind: .destructive, fullWidth: true) {
            model.disconnect()
        }
    }

    private var about: [String] {
        var paragraphs: [String] = []
        if activeIsOura {
            paragraphs.append(String(localized: "Reconnect drops the current link, if any, and connects to the ring again. To pair or switch bands, open Devices."))
        } else {
            paragraphs.append(String(localized: "Scan connects to \(deviceName). To pair or switch bands, open Devices."))
        }
        paragraphs.append(String(localized: "Live heart rate is flowing; full strap controls need an encrypted bond."))
        paragraphs.append(String(localized: "Other metrics (R-R, frames, battery, history) need a full sync."))
        return paragraphs
    }
}

// MARK: - Signal rows

/// One row per signal that has to be current for the stream to be trustworthy (heart rate, R-R,
/// connection, history sync, battery, wear). The whole list is a leaf that owns LiveState so its 1 Hz value
/// refresh does not re-render the page.
private struct LiveSignalRows: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let activeConnection: Bool
    /// Resolved by the parent (#2075): the battery row below must describe the ACTIVE device.
    let activeIsWhoop: Bool

    private struct Row: Identifiable {
        let title: String
        let value: String
        let detail: String
        let icon: String
        let tone: StrandTone
        var id: String { title }
    }

    /// The ACTIVE device's charge, or nil when it has not reported one.
    private var activeBatteryPct: Int? {
        LiveConsoleReadout.batteryPercent(
            activeIsWhoop: activeIsWhoop, whoopPct: live.batteryPct, ringPct: live.ouraBatteryPct,
        )
    }

    private var displayHR: Int? { model.bpm }
    /// Oura ring actively streaming live HR — trusted stream without a WHOOP bond (see LiveView.ringStreaming).
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    /// #218: a live link for the wear stat = a WHOOP bond OR an Oura HR stream. Oura streams only while worn
    /// (PPG needs skin contact) and stops when removed, so `ringStreaming` doubles as its wear signal.
    private var liveLink: Bool { activeConnection || ringStreaming }
    /// Streaming ⟹ worn: keeps a stale `worn=false` (from a prior WHOOP WRIST_OFF, never reset on a source
    /// switch) from reading "Off wrist" while an Oura ring streams. For WHOOP `ringStreaming` is always
    /// false, so this is just `live.worn`. #218.
    private var wornNow: Bool {
        // An Oura ring reports a precise live wear/charge state (live-HR presence + charger STATE + a
        // removal watchdog), so prefer it — it drops to not-worn the moment the ring is off the finger or
        // on the charger, unlike `ringStreaming`, which lingers. WHOOP has no such signal (ouraWearState
        // stays nil), so it keeps the bond-worn / stream fallback. #218.
        if let w = live.ouraWearState { return w == .worn }
        return live.worn || ringStreaming
    }

    var body: some View {
        NoopListSection("Signal") {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                signalRow(row)
                    .accessibilityLabel("\(row.title): \(row.value). \(row.detail)")
            }
        }
    }

    /// A list row whose detail may wrap: a sync error or a backfill count is diagnostic text that has to be
    /// read whole. Same metrics as `NoopListRow`.
    private func signalRow(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Image(systemName: row.icon)
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(row.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(row.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(row.value)
                .font(StrandFont.subhead)
                .foregroundStyle(row.tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2 + 2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var connectionTone: StrandTone {
        if (activeConnection && live.encryptedBond) || ringStreaming { return .positive }
        if activeConnection || live.connected { return .warning }
        return .neutral
    }

    private var batteryTone: StrandTone {
        guard let pct = activeBatteryPct else { return .neutral }
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .neutral
    }

    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private var syncDetail: String {
        if let err = live.lastSyncError { return err }
        if live.backfilling { return String(localized: "\(live.decodedChunksThisSession) decoded, \(live.consoleChunksThisSession) console") }
        return live.lastSyncedAt == nil ? String(localized: "No completed offload yet") : String(localized: "Last offload completed")
    }

    private var rows: [Row] {
        [
            .init(title: String(localized: "Heart rate"),
                  value: displayHR.map { "\($0) bpm" } ?? String(localized: "Missing"),
                  detail: (activeConnection || ringStreaming) ? String(localized: "Streaming now") : String(localized: "No active stream"),
                  icon: "waveform.path.ecg", tone: .neutral),
            .init(title: String(localized: "R-R intervals"),
                  value: live.rrRecent.isEmpty ? String(localized: "Missing") : String(localized: "\(live.rrRecent.count) recent"),
                  detail: rollingRMSSD.map { String(localized: "RMSSD \(Int($0.rounded())) ms") } ?? String(localized: "Needs interval frames"),
                  icon: "point.3.connected.trianglepath.dotted", tone: .neutral),
            .init(title: String(localized: "Connection"),
                  value: activeConnection && live.encryptedBond ? String(localized: "Encrypted") : activeConnection ? String(localized: "Partial") : ringStreaming ? String(localized: "Streaming") : live.connected ? String(localized: "Connected") : String(localized: "Offline"),
                  detail: activeConnection && live.encryptedBond ? String(localized: "Controls unlocked") : ringStreaming ? String(localized: "Authenticated ring stream") : String(localized: "Standard HR is not a full bond"),
                  icon: "lock.shield", tone: connectionTone),
            .init(title: String(localized: "History sync"),
                  value: live.backfilling ? String(localized: "\(live.syncChunksThisSession) chunks") : LiveSyncFormat.lastSyncLabel(live.lastSyncedAt),
                  detail: syncDetail,
                  icon: "clock.arrow.circlepath", tone: live.lastSyncError != nil ? .warning : .neutral),
            .init(title: String(localized: "Battery"),
                  value: activeBatteryPct.map { "\($0) %" } ?? String(localized: "Unknown"),
                  // "by strap" only when a strap is what reported it (#2075).
                  detail: live.isChargingNow ? String(localized: "Charging")
                          : activeIsWhoop ? String(localized: "Last reported by strap")
                          : String(localized: "Last reported by the ring"),
                  icon: "battery.75percent", tone: batteryTone),
            // Wear is only trustworthy on a live link: `worn` defaults true (LiveState) and is only updated
            // by WRIST_ON/OFF events, so while OFFLINE it would otherwise read a false-green "On wrist".
            // Gate the value AND tone on a live link (triage fix for PR#191). #218: `liveLink` includes an
            // Oura HR stream, not just a WHOOP bond.
            .init(title: String(localized: "Wear state"),
                  value: liveLink ? (wornNow ? String(localized: "On wrist") : String(localized: "Off wrist")) : String(localized: "Unknown"),
                  detail: liveLink ? (wornNow ? String(localized: "Eligible for live physiology") : String(localized: "Wear the strap for scoring")) : String(localized: "Connect to read wear state"),
                  icon: "sensor.tag.radiowaves.forward", tone: liveLink && !wornNow ? .warning : .neutral),
        ]
    }
}

// MARK: - R-R strip

/// The recent R-R buffer as bars in milliseconds, the rolling RMSSD, and the last frame and event the strap
/// sent: the proof the stream is genuinely live. Owns LiveState so the ~1 Hz R-R / frame notifies re-render
/// only this card.
private struct LiveRRStrip: View {
    @EnvironmentObject private var live: LiveState
    /// Resolved by the parent (#2075). Passed rather than observed so this leaf keeps owning only LiveState.
    let activeIsWhoop: Bool

    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }

    var body: some View {
        let values = Array(live.rrRecent.suffix(30))
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("R-R intervals")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let rmssd = rollingRMSSD {
                        Text("RMSSD \(Int(rmssd.rounded())) ms")
                            .font(StrandFont.subhead.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityLabel("Rolling RMSSD \(Int(rmssd.rounded())) milliseconds")
                    }
                }
                if values.count >= 2 {
                    Chart {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, ms in
                            BarMark(x: .value("Beat", index), y: .value("Interval", ms), width: .ratio(0.6))
                                .foregroundStyle(StrandPalette.metricCyan)
                                .cornerRadius(NaraChartStyle.barCornerRadius)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                            AxisValueLabel().font(NaraChartStyle.axisFont).foregroundStyle(NaraChartStyle.axisColor)
                        }
                    }
                    .chartYAxisLabel(position: .top, alignment: .leading, spacing: 4) {
                        Text("ms").font(NaraChartStyle.unitFont).foregroundStyle(NaraChartStyle.axisColor)
                    }
                    .frame(height: NoopMetrics.chartHeightCompact)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Recent R-R intervals"))
                    .accessibilityValue(Text(values.suffix(5).map { "\($0) ms" }.joined(separator: ", ")))
                } else {
                    EmptyChartMessage(String(localized: "Waiting for R-R intervals."), height: NoopMetrics.chartHeightCompact)
                }
                VStack(spacing: 0) {
                    detailRow(String(localized: "Last frame"), activeConnection ? (live.lastFrameType ?? "—") : "—")
                    NoopListDivider(leadingInset: 0)
                    detailRow(String(localized: "Last event"), activeConnection ? (live.lastEvent ?? "—") : "—")
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space2)
            Text(value).font(StrandFont.subhead.monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    /// A "feel" RMSSD over the recent R-R buffer — time-gap-unaware on purpose (a live indicator, not a
    /// clinical figure; it's blanked on disconnect by clearBiometrics). nil until ≥3 intervals land.
    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }
}

// MARK: - Strap log

/// The strap log + export controls, on the connection details page. The Test Centre link that used to sit
/// under it is a row of its own on that page.
///
/// This observes `LiveState` rather than scoping anything: a published change there invalidates every
/// observer, so what this card controls is the COST of its own re-evaluation, not whether it happens.
struct LiveLogCard: View {
    /// How many trailing lines the card RENDERS. The buffer stays `LiveState.maxLogLines` (5,000) and Copy /
    /// Save / the export still read all of it, so nothing is lost by drawing less.
    ///
    /// #2521: this card used to render the whole buffer in a non-lazy `VStack`, so every appended line built
    /// and diffed up to 5,000 rows while the visible viewport is 200pt, about fifteen lines. A history drain
    /// plus a re-score burst emits hundreds of lines a minute, and the 80%-of-a-core CPU limit is per
    /// process, so that cost landed on the main thread and the app was killed with `cpu_resource_fatal`
    /// while it was not even frontmost.
    private static let renderedTailLines = 200

    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    /// Backgrounded, nothing is on screen to keep current, and a `LiveState` publish still re-evaluates this
    /// body because an `ObservableObject` invalidates every observer on ANY published change, not only the
    /// property a view reads. So what is cut is the COST of that re-evaluation, which is what the CPU limit
    /// measures: roughly fifteen built rows instead of five thousand, and none at all here.
    ///
    /// Not free, to be exact about what remains: the header and the card are still built per line.
    /// Microseconds against the five thousand `Text` views this removes, but the place to look first if a
    /// background cost survives this. (The Test Centre link, whose `NavigationLink(destination:)` built
    /// `TestCentreView()` eagerly per line, moved out of this card.)
    ///
    /// Gated on `.background` rather than `!= .active` deliberately: `.inactive` is also when iOS takes the
    /// app-switcher snapshot, and blanking the log there would be visible for no benefit. The kill needs
    /// sustained non-frontmost CPU, which is `.background`.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space4) {
                    Text("Strap log").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    // Export the log so people can attach it to a bug report (issue #17 — macOS users
                    // had no way to share it). Copy → clipboard; Save… → a .txt file.
                    Button("Copy") { copyStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                    Button("Save…") { saveStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                }
                if scenePhase == .background {
                    // Same height so returning to the app does not shift the card's layout.
                    Color.clear.frame(height: 200)
                } else {
                    logScroller
                }
            }
        }
    }

    /// The tail of the log, lazily.
    ///
    /// The slice comes from `LiveState.renderedTail`, which snapshots the buffer so a lazily-realized row
    /// cannot index a trimmed array. Its indices are ABSOLUTE positions in `live.log`, which is what makes
    /// them usable as identity: BETWEEN trims, appending a line leaves every other row's id alone, so SwiftUI adds one row
    /// and drops one instead of re-identifying the list. A trim still renumbers, because `Array.removeFirst`
    /// shifts every element down, but that is once per `LiveState.trimSlack` lines and now touches 200 ids
    /// rather than rebuilding 5,000 rows.
    ///
    /// The old `id: \.offset` over `Array(live.log.enumerated())` paid on every line instead: a fresh
    /// 5,000-element array allocated per body evaluation, and a non-lazy `VStack` that built every row even
    /// though the 200pt viewport shows about fifteen.
    ///
    /// `scrollTo` still addresses the true last index, which is always inside the tail.
    private var logScroller: some View {
        let tail = LiveState.renderedTail(live.log, tailLines: Self.renderedTailLines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(tail.indices, id: \.self) { idx in
                        Text(tail[idx]).font(StrandFont.mono(11))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
            }
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .frame(height: 200)
            // On `logRevision`, not `log.count` (#2547). The revision is monotonic and ticks exactly once per
            // coalesced publish; the count plateaus while the ring trims, so it can stay equal across an
            // append and skip a scroll.
            .onChangeCompat(of: live.logRevision) { _ in
                if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    // The strap-log text builder lives on LiveState (`exportableLogText()`) so the macOS Settings
    // shortcut shares the exact same output (#17 / #507). These stay as thin wrappers.
    private func copyStrapLog() {
        PlatformPasteboard.copy(live.exportableLogText())
    }

    private func saveStrapLog() {
        Task {
            // Settings (#507) and Test Centre fetch these extras before exporting; without them this
            // site wrote a same-named file silently missing the "Strap & data" + funnel sections, so
            // which button someone pressed changed what a triager received.
            let extra = await DebugDataDiagnostics.dynamicLines(repo: model.repo)
            FileExport.exportText(live.exportableLogText(extraHeaderLines: extra),
                                  suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
        }
    }
}

