import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Watchdog
//
// The Monitor root shows Watchdog at a glance (`WatchdogLiveCard`: the state word, one line, the six
// vitals' values) and its newest alerts (`WatchdogEventsCard`). One tap down, `WatchdogPage` has each
// vital's half-hour trace, three weeks of alerts on a timeline with their totals, the full alert list and
// the explanation. A vital opens `WatchdogVitalSheet` (its trace on a clock axis against what Watchdog
// expected); an alert opens `WatchdogEventSheet` (what Watchdog saw at the alert's strongest moment).
//
// What each vital is called ("In range", "Off", ...) is decided by `WatchdogLiveSnapshot`, unchanged.

private struct WatchdogPick: Identifiable, Equatable {
    let id: String
}

enum WatchdogTone {
    static func color(_ state: HeroRings.WatchdogState) -> Color {
        switch state {
        case .calm: return StrandPalette.statusPositive
        case .watching: return StrandPalette.statusWarning
        case .alert: return StrandPalette.statusCritical
        case .waiting, .offWrist: return StrandPalette.textTertiary
        }
    }

    static func tone(_ state: HeroRings.WatchdogState) -> StrandTone {
        switch state {
        case .calm: return .positive
        case .watching: return .warning
        case .alert: return .critical
        case .waiting, .offWrist: return .neutral
        }
    }
}

/// The user's temperature unit, resolved the way every Watchdog view does.
private struct WatchdogUnits {
    let unitSystemRaw: String
    let temperatureRaw: String

    var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .imperial,
                                     override: temperatureRaw)
    }
    var fahrenheit: Bool { temperatureUnit == .fahrenheit }
}

extension WatchdogLiveSnapshot {
    /// Whether any vital has a reading in the half-hour (a strap is on and streaming).
    var hasReadings: Bool { metrics.contains { $0.status != "No reading" } }
}

// MARK: - Monitor root card

/// The Monitor root's Watchdog card: the state word and one line (a link to the Watchdog page), then the
/// six vitals as values, each opening its half-hour sheet. With nothing to read it stays one row.
///
/// This view is always mounted on the Monitor root, so it keeps the two jobs that must live somewhere that
/// is always there: asking for notification permission, and presenting the note sheet that
/// `BaselineStore.noteAfterSent` raises after an alert is delivered. Keep exactly one presenter of
/// `showEpisodeNoteSheet`; other screens open the note sheet with their own local flag.
@MainActor
struct WatchdogLiveCard: View {
    @EnvironmentObject private var store: BaselineStore
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var picked: WatchdogPick?

    private var units: WatchdogUnits { WatchdogUnits(unitSystemRaw: unitSystemRaw, temperatureRaw: temperatureRaw) }

    private var snapshot: WatchdogLiveSnapshot {
        WatchdogLiveSnapshot(store: store, temperatureUnit: units.temperatureUnit)
    }

    private var state: HeroRings.WatchdogState { HeroRings.watchdogState(store.watchdogResult) }

    /// Before the service's first check the card keeps the layout of a live half-hour, redacted.
    private var checking: Bool { store.watchdogResult == nil }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space2), count: 3)

    var body: some View {
        let snap = snapshot
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                MonitorLink(route: .watchdog) {
                    WatchdogStatusRow(state: state,
                                      line: MonitorLabels.watchdogLine(headline: store.watchdogResult?.headline,
                                                                       hasReadings: snap.hasReadings),
                                      isLive: snap.isLive,
                                      lastTickUnix: store.watchdogResult?.lastTickUnix,
                                      intervalMinutes: store.liveIntervalMinutes,
                                      showsChevron: true)
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityHint("Opens Watchdog")

                if let notice = MonitorLabels.watchdogNotice(snap.certaintyCaption) {
                    InlineNotice(notice, tone: .warning, placement: .inCard)
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .padding(.bottom, NoopMetrics.space3)
                }
                if checking || snap.hasReadings {
                    LazyVGrid(columns: columns, spacing: NoopMetrics.space2) {
                        ForEach(snap.metrics) { row in
                            Button { picked = WatchdogPick(id: row.id) } label: {
                                WatchdogVitalCell(row: row)
                            }
                            .buttonStyle(LiquidPressStyle())
                            .accessibilityHint("Shows the last 30 minutes")
                        }
                    }
                    .padding([.horizontal, .bottom], NoopMetrics.cardPadding)
                    .loadingPlaceholder(checking)
                }
                if store.pendingEpisodeNote != nil {
                    NoopListDivider(leadingInset: 0)
                    WatchdogNoteButton(title: "Add a note about the last alert") {
                        store.showEpisodeNoteSheet = true
                    }
                }
            }
        }
        .onAppear { WatchdogNotifier.requestAuthorization() }
        .sheet(item: $picked) { pick in
            let snap = snapshot
            if let row = snap.metrics.first(where: { $0.id == pick.id }) {
                WatchdogVitalSheet(row: row,
                                   trace: store.watchdogResult.flatMap { WatchdogTrace(result: $0, row: row, fahrenheit: units.fahrenheit) },
                                   contextNote: store.activityContextNote)
            }
        }
        .sheet(isPresented: $store.showEpisodeNoteSheet) {
            WatchdogEpisodeNoteSheet(deviceId: repo.deviceId) {
                store.showEpisodeNoteSheet = false
            }
            .environmentObject(store)
        }
    }
}

/// The state word and its one line, with the time of the last check only once it is overdue.
private struct WatchdogStatusRow: View {
    let state: HeroRings.WatchdogState
    let line: String
    let isLive: Bool
    let lastTickUnix: Int?
    let intervalMinutes: Int
    var showsChevron: Bool = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            // The dot breathes only while the half-hour is genuinely live, and never under Reduce Motion or
            // the quiet-motion gate (`ConnectionDot` consults both).
            ConnectionDot(tone: WatchdogTone.tone(state), pulsing: isLive, size: 10)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(HeroRings.watchdogLabel(state))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(line)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    // Wraps at accessibility sizes so the reason is not cut to "No readings in the last 3...".
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: NoopMetrics.space2)
            if let lastTickUnix {
                TimelineView(.everyMinute) { context in
                    if let stale = MonitorLabels.staleCheckTime(lastTickUnix: lastTickUnix,
                                                                 nowUnix: Int(context.date.timeIntervalSince1970),
                                                                 intervalMinutes: intervalMinutes) {
                        Text(stale)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .fixedSize()
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watchdog, \(HeroRings.watchdogLabel(state)). \(line)")
    }
}

/// A vital's value and unit, the unit drawn in `textSecondary` beside the number.
private struct WatchdogValueLine: View {
    let formatted: String

    var body: some View {
        let parts = MonitorLabels.splitValue(formatted)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.value ?? "—")
                .font(StrandFont.number(20))
                .foregroundStyle(parts.value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            if parts.value != nil, let unit = parts.unit {
                Text(MonitorLabels.unit(unit, fahrenheit: false))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .monospacedDigit()
    }
}

/// One vital on the root card: name, value with its unit, the call. Fixed height.
private struct WatchdogVitalCell: View {
    let row: WatchdogLiveSnapshot.MetricRow

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(row.name)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            WatchdogValueLine(formatted: row.now)
            Text(MonitorLabels.watchdogStatus(row.status))
                .font(StrandFont.footnote.weight(.medium))
                .foregroundStyle(row.tone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopInsetSurface())
        .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchdogVitalCell.spoken(row))
    }

    static func spoken(_ row: WatchdogLiveSnapshot.MetricRow) -> String {
        let parts = MonitorLabels.splitValue(row.now)
        let value = parts.value.map { "\($0) \(MonitorLabels.unit(parts.unit ?? "", fahrenheit: false))" } ?? "no reading"
        return "\(row.name), \(value), \(MonitorLabels.watchdogStatus(row.status))"
    }
}

/// "Add a note about the last alert", as a full-width row action.
private struct WatchdogNoteButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "square.and.pencil")
                    .font(StrandFont.icon(.row))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(StrandFont.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(StrandPalette.accent)
            .padding(.horizontal, NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Watchdog page

/// One tap down from the Monitor root (and the Today Watchdog ring): the live call with when it was made,
/// each vital's half-hour, three weeks of alerts and the explanation.
@MainActor
struct WatchdogPage: View {
    @EnvironmentObject private var store: BaselineStore
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var picked: WatchdogPick?
    /// A local flag, not `store.showEpisodeNoteSheet`: the Monitor root presents that one, and two sheets
    /// bound to one store flag would both try to present.
    @State private var notePresented = false
    @State private var selectedDay: Date?
    /// Only the DEBUG screenshot hook opens an alert from the page itself; the rows open their own.
    @State private var pickedAlert: WatchdogPick?
    @State private var demoApplied = false

    private var units: WatchdogUnits { WatchdogUnits(unitSystemRaw: unitSystemRaw, temperatureRaw: temperatureRaw) }

    private var snapshot: WatchdogLiveSnapshot {
        WatchdogLiveSnapshot(store: store, temperatureUnit: units.temperatureUnit)
    }

    private var state: HeroRings.WatchdogState { HeroRings.watchdogState(store.watchdogResult) }

    #if DEBUG
    private func applyDemoSheet() {
        guard !demoApplied, store.watchdogResult != nil else { return }
        demoApplied = true
        if let id = MonitorDemoHooks.vitalSheet { picked = WatchdogPick(id: id) }
        if let index = MonitorDemoHooks.alertSheet, alerts.indices.contains(index) {
            pickedAlert = WatchdogPick(id: alerts[index].episodeId)
        }
        if MonitorDemoHooks.sheet == "note" { notePresented = true }
    }
    #endif

    private var alerts: [WatchdogEpisodeLedgerRow] {
        store.episodeLedger.sorted { $0.openedUnix > $1.openedUnix }
    }

    private let columns = [GridItem(.flexible(), spacing: NoopMetrics.space2),
                           GridItem(.flexible(), spacing: NoopMetrics.space2)]

    var body: some View {
        let snap = snapshot
        ScreenScaffold(title: "Watchdog", titleDisplay: .navigationBar) {
            statusCard(snap)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last 30 minutes")
                if let result = store.watchdogResult, snap.hasReadings {
                    LazyVGrid(columns: columns, spacing: NoopMetrics.space2) {
                        ForEach(snap.metrics) { row in
                            Button { picked = WatchdogPick(id: row.id) } label: {
                                WatchdogVitalTile(row: row,
                                                  trace: WatchdogTrace(result: result, row: row,
                                                                       fahrenheit: units.fahrenheit))
                            }
                            .buttonStyle(LiquidPressStyle())
                            .accessibilityHint("Shows the last 30 minutes")
                        }
                    }
                } else if store.watchdogResult == nil {
                    // Before the first check: the tiles' layout, redacted, so nothing moves when it lands.
                    LazyVGrid(columns: columns, spacing: NoopMetrics.space2) {
                        ForEach(snap.metrics) { row in
                            WatchdogVitalTile(row: row, trace: nil)
                        }
                    }
                    .loadingPlaceholder(true)
                } else {
                    NoopCard {
                        Text("No readings in the last 30 minutes")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            alertsSection
            AboutDisclosure("About Watchdog", paragraphs: aboutParagraphs)
        }
        .onAppear { WatchdogNotifier.requestAuthorization() }
        #if DEBUG
        .task(id: store.watchdogResult?.lastTickUnix ?? 0) { applyDemoSheet() }
        #endif
        .sheet(item: $picked) { pick in
            let snap = snapshot
            if let row = snap.metrics.first(where: { $0.id == pick.id }) {
                WatchdogVitalSheet(row: row,
                                   trace: store.watchdogResult.flatMap { WatchdogTrace(result: $0, row: row, fahrenheit: units.fahrenheit) },
                                   contextNote: store.activityContextNote)
            }
        }
        .sheet(item: $pickedAlert) { pick in
            if let row = alerts.first(where: { $0.episodeId == pick.id }) {
                WatchdogEventSheet(row: row, fahrenheit: units.fahrenheit)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $notePresented) {
            WatchdogEpisodeNoteSheet(deviceId: repo.deviceId) { notePresented = false }
                .environmentObject(store)
        }
    }

    private func statusCard(_ snap: WatchdogLiveSnapshot) -> some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                WatchdogStatusRow(state: state,
                                  line: MonitorLabels.watchdogLine(headline: store.watchdogResult?.headline,
                                                                   hasReadings: snap.hasReadings),
                                  isLive: snap.isLive, lastTickUnix: nil,
                                  intervalMinutes: store.liveIntervalMinutes)
                let hasDetail = (store.watchdogResult?.lastTickUnix ?? 0) > 0
                    || (store.eventRecovery.map { $0.status != .noReference } ?? false)
                    || MonitorLabels.watchdogNotice(snap.certaintyCaption) != nil
                if hasDetail {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if let result = store.watchdogResult, result.lastTickUnix > 0 {
                        Text("Checked \(WatchdogEventCopy.clock(result.lastTickUnix)) · every \(store.liveIntervalMinutes) min")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .monospacedDigit()
                    }
                    if let recovery = store.eventRecovery, recovery.status != .noReference {
                        Text(recovery.headline)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = MonitorLabels.watchdogNotice(snap.certaintyCaption) {
                        InlineNotice(notice, tone: .warning, placement: .inCard)
                    }
                }
                .padding(.leading, NoopMetrics.cardPadding + 24)
                .padding(.trailing, NoopMetrics.cardPadding)
                .padding(.bottom, NoopMetrics.cardPadding)
                }
                if store.pendingEpisodeNote != nil {
                    NoopListDivider(leadingInset: 0)
                    WatchdogNoteButton(title: "Add a note about the last alert") { notePresented = true }
                }
            }
        }
    }

    @ViewBuilder private var alertsSection: some View {
        let rows = alerts
        let totals = MonitorLabels.alertTotals(rows)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Alerts", trailing: "21 days")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text(selectionLine(rows))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .monospacedDigit()
                        .transaction { $0.animation = nil }
                    WatchdogAlertTimeline(rows: rows, window: WatchdogAlertTimeline.window(),
                                          state: store.watchdogResult == nil && rows.isEmpty ? .loading : .ready,
                                          selection: $selectedDay)
                }
            }
            if !rows.isEmpty {
                StatGrid([StatItem("Alerts", value: "\(totals.count)"),
                          StatItem("Total time", value: MonitorLabels.minutesText(totals.totalMinutes)),
                          StatItem("Longest", value: MonitorLabels.minutesText(totals.longestMinutes))],
                         columns: 3)
                WatchdogEventsCard(limit: nil)
            }
        }
    }

    /// Above the timeline: the alerts on the selected day, or the three weeks in one line.
    private func selectionLine(_ rows: [WatchdogEpisodeLedgerRow]) -> String {
        guard let selectedDay else {
            if rows.isEmpty { return " " }
            return rows.count == 1 ? "1 alert in the last 21 days" : "\(rows.count) alerts in the last 21 days"
        }
        let cal = Calendar.current
        let bars = WatchdogAlertTimeline.bars(rows).filter { cal.isDate($0.day, inSameDayAs: selectedDay) }
        let date = ReadoutContent.dateLine(selectedDay, period: .day)
        guard !bars.isEmpty else { return "\(date) · No alerts" }
        if bars.count == 1, let bar = bars.first {
            let midnight = cal.startOfDay(for: selectedDay)
            let start = Int(midnight.addingTimeInterval(bar.startHour * 3600).timeIntervalSince1970)
            let end = Int(midnight.addingTimeInterval(bar.endHour * 3600).timeIntervalSince1970)
            return "\(date) · \(WatchdogEventCopy.clock(start))–\(WatchdogEventCopy.clock(end)) · \(WatchdogEventCopy.severityTitle(bar.severity))"
        }
        return "\(date) · \(bars.count) alerts"
    }

    private var aboutParagraphs: [String] {
        var out = [
            "Watchdog checks the last half-hour of heart rate, resting heart rate, HRV, temperature, breathing and SpO₂ against what it expects for you at that point in your day. When a half-hour starts to look unlike your usual, it opens an alert with the readings that caused it.",
            "Each vital's band is wider while Watchdog is still learning it. A vital needs about 14 good still minutes before its own band is used; until then Watchdog shows the reading without calling it in range or off.",
            "An alert opens when the whole half-hour stays unlike your usual, not from one reading. Watchdog is separate from Charge and is not a diagnosis.",
        ]
        if let line = WatchdogEventCopy.exerciseLine(store.watchdogResult?.exercise) { out.append(line) }
        if let note = store.activityContextNote, !note.isEmpty { out.append(note) }
        return out
    }
}

/// One vital on the Watchdog page: name and call, value, and its half-hour as a small trace.
private struct WatchdogVitalTile: View {
    let row: WatchdogLiveSnapshot.MetricRow
    let trace: WatchdogTrace?
    @State private var noSelection: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(spacing: NoopMetrics.space1) {
                Text(row.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: NoopMetrics.space1)
                Text(MonitorLabels.watchdogStatus(row.status))
                    .font(StrandFont.footnote.weight(.medium))
                    .foregroundStyle(row.tone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            WatchdogValueLine(formatted: row.now)
            Group {
                if let trace, !trace.readings.isEmpty {
                    WatchdogWindowChart(trace: trace, compact: true, selection: $noSelection, height: 44,
                                        accessibilityTitle: row.name)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Color.clear
                }
            }
            .frame(height: 44)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopInsetSurface())
        .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchdogVitalCell.spoken(row))
    }
}

// MARK: - Vital sheet

/// One vital's half-hour: the reading (or the minute under the finger), the trace against what Watchdog
/// expected and its usual band, the numbers behind the call, and the method in About.
private struct WatchdogVitalSheet: View {
    let row: WatchdogLiveSnapshot.MetricRow
    let trace: WatchdogTrace?
    let contextNote: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date?

    private var unit: String {
        trace?.unit ?? MonitorLabels.unit(MonitorLabels.splitValue(row.now).unit ?? "", fahrenheit: false)
    }

    private var selectedMinute: WatchdogTrace.Minute? {
        guard let selection, let trace else { return nil }
        let readings = trace.readings
        return ChartSelection.nearestIndex(to: selection, in: readings.map(\.time)).map { readings[$0] }
    }

    private var spanLine: String {
        guard let trace else { return "Last 30 minutes" }
        let start = WatchdogEventCopy.clock(Int(trace.window.lowerBound.timeIntervalSince1970))
        let end = WatchdogEventCopy.clock(Int(trace.window.upperBound.timeIntervalSince1970))
        return "\(start)–\(end)"
    }

    private var readout: ReadoutContent {
        if let minute = selectedMinute {
            var context: [String] = []
            if let e = minute.expected { context.append("Expected \(MonitorLabels.number(e, unit: unit))") }
            if let e = minute.expected, let h = minute.half {
                context.append("range \(MonitorLabels.range(e - h, e + h, unit: unit))")
            }
            return ReadoutContent(dateLine: WatchdogEventCopy.clock(Int(minute.time.timeIntervalSince1970)),
                                  value: minute.observed.map { MonitorLabels.number($0, unit: unit) }, unit: unit,
                                  context: context.joined(separator: " · "))
        }
        let status = MonitorLabels.watchdogStatus(row.status)
        let context: String
        switch row.status {
        case "Live", "Learning": context = "Still learning your range"
        case "No reading": context = "No reading in this half-hour"
        default:
            let expected = MonitorLabels.splitValue(row.expected).value
            context = expected.map { "\(status) · expected \($0) \(unit)" } ?? status
        }
        return ReadoutContent(dateLine: spanLine, value: MonitorLabels.splitValue(row.now).value, unit: unit,
                              context: context)
    }

    private var stats: [StatItem] {
        let expected = MonitorLabels.splitValue(row.expected)
        let range = row.rangeLabel.map { MonitorLabels.splitValue($0.replacingOccurrences(of: "Range ", with: "")) }
        let readings = trace?.readings.count ?? 0
        let total = trace?.minutes.count ?? WatchdogConfig.seqLen
        return [
            StatItem("Expected now", value: expected.value, unit: expected.value == nil ? nil : unit),
            StatItem("Usual range", value: range?.value ?? (row.status == "No reading" ? nil : "Learning"),
                     unit: range?.value == nil ? nil : unit),
            StatItem("Confidence", value: MonitorLabels.confidence(row.trustPct) ?? "Learning"),
            trace?.pointsOnly == true
                ? StatItem("Readings", value: "\(readings)")
                : StatItem("Readings", value: "\(readings) of \(total)", unit: "min"),
        ]
    }

    private var aboutParagraphs: [String] {
        var out: [String] = []
        switch row.status {
        case "In range":
            out.append("The reading is inside the range Watchdog expects for you at this point in your day.")
        case "Off":
            out.append("The reading is outside the range Watchdog expects for you right now. An alert opens when the whole half-hour stays unlike your usual, not from one reading.")
        case "Live", "Learning":
            out.append("Watchdog is still learning how much this vital moves for you, so it shows the reading without calling it in range or off.")
        default:
            out.append("There is no reading for this vital in the last half-hour.")
        }
        out.append("The dashed line is what Watchdog expected each minute and the shaded band is your usual range around it. While Watchdog is still learning this vital the band is wider and its edges are dashed; it needs about 14 good still minutes.")
        if trace?.pointsOnly == true {
            out.append("\(row.name) is only read at still minutes, so each reading is a point at the minute it was taken.")
        }
        if let trust = MonitorLabels.confidence(row.trustPct) {
            out.append("Confidence \(trust.lowercased()): \(row.trustPct) % trust in this vital's band.")
        }
        if let contextNote, !contextNote.isEmpty { out.append(contextNote) }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    ValueReadout(readout, isScrubbing: selection != nil)
                    NoopCard {
                        if let trace {
                            WatchdogWindowChart(trace: trace, selection: $selection,
                                                height: NoopMetrics.chartHeightSecondary + 60,
                                                accessibilityTitle: row.name)
                        } else {
                            EmptyChartMessage("No readings in this half-hour",
                                              height: NoopMetrics.chartHeightSecondary + 60)
                        }
                    }
                    StatGrid(stats, columns: 2)
                    AboutDisclosure("About this trace", paragraphs: aboutParagraphs)
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(row.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }
}

// MARK: - Alerts

/// Watchdog's alerts from the on-phone ledger, newest first. `limit` shows the newest few (the Monitor
/// root); nil shows all 21 days (the Watchdog page). Each row opens what Watchdog saw at its peak.
@MainActor
struct WatchdogEventsCard: View {
    var limit: Int? = 3
    @EnvironmentObject private var store: BaselineStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var picked: WatchdogPick?

    private var fahrenheit: Bool {
        WatchdogUnits(unitSystemRaw: unitSystemRaw, temperatureRaw: temperatureRaw).fahrenheit
    }

    private var events: [WatchdogEpisodeLedgerRow] {
        store.episodeLedger.sorted { $0.openedUnix > $1.openedUnix }
    }

    var body: some View {
        let all = events
        let shown = limit.map { Array(all.prefix($0)) } ?? all
        NoopCard(padding: 0) {
            if all.isEmpty {
                if store.watchdogResult == nil {
                    // Before the service's first check the ledger may not be read yet: a placeholder row,
                    // not "no alerts".
                    WatchdogEventRow(row: Self.placeholder, fahrenheit: false)
                        .loadingPlaceholder(true)
                } else {
                    Text("No alerts in the last 21 days")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight + 4, alignment: .leading)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.episodeId) { index, row in
                        if index > 0 { NoopListDivider(leadingInset: NoopMetrics.cardPadding + 20) }
                        Button { picked = WatchdogPick(id: row.episodeId) } label: {
                            WatchdogEventRow(row: row, fahrenheit: fahrenheit)
                        }
                        .buttonStyle(LiquidPressStyle())
                        .accessibilityHint("Shows why this alert opened")
                    }
                }
            }
        }
        .sheet(item: $picked) { pick in
            if let row = events.first(where: { $0.episodeId == pick.id }) {
                WatchdogEventSheet(row: row, fahrenheit: fahrenheit)
                    .environmentObject(store)
            }
        }
    }

    private static let placeholder = WatchdogEpisodeLedgerRow(
        episodeId: "placeholder", deviceId: "", openedUnix: 0, lastUnix: 1_200, closedUnix: 1_200,
        maxSeverity: "candidate", safety: false, personalOff: false, notifyDelivery: "", liveAlerts: true,
        headline: "Heart rate is drifting above usual")
}

private struct WatchdogEventRow: View {
    let row: WatchdogEpisodeLedgerRow
    let fahrenheit: Bool

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Circle()
                // The loading placeholder row draws a neutral dot: redaction does not hide a fill colour.
                .fill(row.episodeId == "placeholder" ? StrandPalette.textTertiary.opacity(0.4)
                                                      : WatchdogEventCopy.tone(row.maxSeverity))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(WatchdogEventCopy.severityTitle(row.maxSeverity))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(WatchdogEventCopy.shortWhen(row.openedUnix))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(MonitorLabels.alertReason(row, fahrenheit: fahrenheit))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(WatchdogEventCopy.durationLine(row))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight + 4, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Alert sheet

/// What Watchdog saw at the strongest moment of one alert, how it unfolded, the context and the note.
private struct WatchdogEventSheet: View {
    let row: WatchdogEpisodeLedgerRow
    let fahrenheit: Bool
    @EnvironmentObject private var store: BaselineStore
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var notePresented = false

    private var annotation: WatchdogEpisodeAnnotation? {
        store.episodeAnnotations.first { $0.episodeId == row.episodeId }
    }

    private var signals: [WatchdogSignalEvidence] {
        let hot = Set(row.contributing ?? [])
        return (row.signals ?? [])
            .filter { $0.observed != nil }
            .sorted { a, b in
                let ah = hot.contains(a.name), bh = hot.contains(b.name)
                if ah != bh { return ah }
                return a.energy > b.energy
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    summary
                    WatchdogEpisodeStrip(row: row)
                    whySection
                    factsSection("Context", rows: contextRows)
                    factsSection("Checks", rows: checkRows)
                    noteSection
                    AboutDisclosure("About alerts", paragraphs: [
                        "Watchdog opens an alert when a half-hour stays unlike your usual. The readings shown are from the alert's strongest moment; the vitals marked as drivers are the ones that opened it.",
                        "Each strip spans the range Watchdog expected for that vital at that moment: the hatched part is the usual range, the tick is the expected value and the dot is the reading.",
                        "Checks off usual counts Watchdog's checks (one every few minutes) that found the half-hour off usual, not minutes.",
                        "Not a diagnosis. Separate from Charge.",
                    ])
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(WatchdogEventCopy.severityTitle(row.maxSeverity))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(minWidth: 460, minHeight: 640)
        #endif
        .sheet(isPresented: $notePresented) {
            WatchdogEpisodeNoteSheet(deviceId: repo.deviceId) { notePresented = false }
                .environmentObject(store)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text("\(WatchdogEventCopy.longWhen(row.openedUnix)) · \(WatchdogEventCopy.durationLine(row))")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
            Text(row.headline ?? WatchdogEventCopy.reasonLine(row, fahrenheit: fahrenheit))
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var whySection: some View {
        let hot = Set(row.contributing ?? [])
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Why it opened", trailing: row.peakUnix.map { "at \(WatchdogEventCopy.clock($0))" })
            NoopCard(padding: 0) {
                if signals.isEmpty {
                    Text("Recorded before Watchdog saved the readings behind each alert")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(NoopMetrics.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(signals.enumerated()), id: \.element.name) { index, signal in
                            if index > 0 { NoopListDivider() }
                            WatchdogSignalRow(signal: signal, hot: hot.contains(signal.name),
                                              severity: row.maxSeverity, fahrenheit: fahrenheit)
                        }
                    }
                }
            }
        }
    }

    private var contextRows: [(String, String)] {
        var rows = [("Movement", WatchdogEventCopy.activity(row.activityLabel) ?? "Not known"),
                    ("Pattern", WatchdogEventCopy.eventLabel(row.eventLabel) ?? "Not labelled")]
        if let comparison = WatchdogEventCopy.exerciseComparison(row.exercise) {
            rows.append(("Compared with", comparison))
        }
        rows.append(("Notification", WatchdogEventCopy.delivery(row.notifyDelivery)))
        return rows
    }

    private var checkRows: [(String, String)] {
        // `offMinutes` keeps one stamp per live check that found the half-hour off usual, so this counts
        // checks, not minutes.
        var rows = [("Checks off usual", "\(row.offMinutes.count)")]
        if row.unavailableMinutes > 0 { rows.append(("Minutes without data", "\(row.unavailableMinutes)")) }
        return rows
    }

    private func factsSection(_ title: LocalizedStringKey, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(title)
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, fact in
                        if index > 0 { NoopListDivider() }
                        WatchdogFactRow(title: fact.0, value: fact.1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var noteSection: some View {
        if let annotation {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Your note")
                NoopCard(padding: annotation.status == .pending ? 0 : NoopMetrics.cardPadding) {
                    switch annotation.status {
                    case .entered:
                        let lines = WatchdogEventCopy.noteLines(annotation)
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            if lines.isEmpty {
                                noteText("Saved with no details")
                            } else {
                                ForEach(lines, id: \.self) { noteText($0) }
                            }
                        }
                    case .pending:
                        WatchdogNoteButton(title: "Add a note about this alert") { notePresented = true }
                    case .skipped:
                        noteText("Skipped")
                    case .expired:
                        noteText("The note window has closed")
                    }
                }
            }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One vital at the alert's peak: its name and role, the value, and a strip placing it against the range
/// Watchdog expected.
private struct WatchdogSignalRow: View {
    let signal: WatchdogSignalEvidence
    let hot: Bool
    let severity: String
    let fahrenheit: Bool

    private var isTemp: Bool { signal.name == "Temp" }
    private func shown(_ v: Double) -> Double { isTemp && fahrenheit ? UnitFormatter.celsiusToFahrenheit(v) : v }

    private var strip: (domain: ClosedRange<Double>, band: ClosedRange<Double>?, expected: Double, observed: Double)? {
        guard let observed = signal.observed, let expected = signal.reconstructed ?? signal.usual,
              observed.isFinite, expected.isFinite else { return nil }
        let half = signal.rangeHalf * (isTemp && fahrenheit ? 9.0 / 5.0 : 1)
        let e = shown(expected), o = shown(observed)
        let reach = max(half * 3, abs(o - e) * 1.25, 0.5)
        return ((e - reach)...(e + reach), half > 0 ? (e - half)...(e + half) : nil, e, o)
    }

    private var outside: Bool {
        guard let strip, let band = strip.band else { return false }
        return !band.contains(strip.observed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(WatchdogEventCopy.vitalName(signal.name))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(hot ? "Drove this alert" : "Not a driver")
                        .font(StrandFont.footnote.weight(hot ? .medium : .regular))
                        .foregroundStyle(hot ? WatchdogEventCopy.tone(severity) : StrandPalette.textTertiary)
                }
                Spacer(minLength: NoopMetrics.space2)
                VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                    WatchdogValueLine(formatted: WatchdogEventCopy.value(signal.observed, signal: signal,
                                                                         fahrenheit: fahrenheit))
                    Text(WatchdogEventCopy.expectedLine(signal, fahrenheit: fahrenheit)
                        .replacingOccurrences(of: " /min", with: " rpm"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                }
            }
            if let strip {
                RangeStrip(domain: strip.domain, band: strip.band, reference: strip.expected, marker: strip.observed,
                           markerColor: outside ? WatchdogEventCopy.tone(severity) : StrandPalette.textPrimary)
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchdogFactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: NoopMetrics.space2)
            Text(value)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// How one alert unfolded: a bar from open to close with a tick at every check that found it off usual
/// and a dot at its strongest moment, then the three times.
private struct WatchdogEpisodeStrip: View {
    let row: WatchdogEpisodeLedgerRow

    private var end: Int { max(row.closedUnix ?? row.lastUnix, row.openedUnix + 60) }

    private func fraction(_ unix: Int) -> CGFloat {
        let span = Double(end - row.openedUnix)
        return CGFloat(min(1, max(0, Double(unix - row.openedUnix) / max(span, 1))))
    }

    var body: some View {
        let tone = WatchdogEventCopy.tone(row.maxSeverity)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(tone.opacity(0.22)).frame(height: 10)
                        ForEach(row.offMinutes, id: \.self) { minute in
                            Rectangle().fill(tone)
                                .frame(width: 2, height: 10)
                                .offset(x: min(max(0, w * fraction(minute) - 1), max(0, w - 2)))
                        }
                        if let peak = row.peakUnix {
                            Circle().fill(tone)
                                .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 2))
                                .frame(width: 16, height: 16)
                                .offset(x: min(max(0, w * fraction(peak) - 8), max(0, w - 16)))
                        }
                    }
                    .frame(width: w, height: geo.size.height)
                }
                .frame(height: 16)
                .accessibilityHidden(true)
                HStack(alignment: .top, spacing: NoopMetrics.space2) {
                    time("Opened", WatchdogEventCopy.clock(row.openedUnix), alignment: .leading)
                    time("Strongest", row.peakUnix.map(WatchdogEventCopy.clock) ?? "—", alignment: .center)
                    time("Closed", row.closedUnix.map(WatchdogEventCopy.clock) ?? "Open", alignment: .trailing)
                }
            }
        }
    }

    private func time(_ label: String, _ value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: NoopMetrics.spaceHalf) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        .accessibilityElement(children: .combine)
    }
}
