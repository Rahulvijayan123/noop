import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The Monitor tab: Watchdog for the last half-hour, its newest alerts, then the last scored night's vitals
/// against their usuals. Each piece is a glance; depth is one tap down (`WatchdogPage`, the vital sheets,
/// the alert sheets, `BaselineVitalPage`). Pipeline diagnostics and the clinician summary sit in the header
/// menu.
struct BaselineMonitorView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var store: BaselineStore
    @EnvironmentObject var router: NavRouter
    @State private var summary: ClinicianSummary?
    /// Owner-scoped diagnostics are only offered to an enrolled Nara account (the page errors otherwise).
    @State private var pipelineAvailable = false
    /// Set when the tab appeared before the first nights loaded (see `BaselineVitalPage`).
    @State private var appearedWithoutNights = false

    private var days: [DailyMetric] { store.displayDays(from: repo.days) }

    var body: some View {
        ScreenScaffold(
            title: "Monitor",
            onRefresh: { await repo.refresh(); store.rescore(days: days) },
            trailing: {
                HStack(spacing: NoopMetrics.space2) {
                    moreMenu
                    HeaderSettingsButton()
                }
            }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Watchdog")
                WatchdogLiveCard()
            }
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Alerts", action: .monitorLink(label: "See all", route: .watchdog))
                WatchdogEventsCard(limit: 3)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Baseline", trailing: nightLabel)
                BaselineVitalsCard()
            }
        }
        .onAppear {
            let tape = days
            if store.evaluation == nil, let last = tape.last?.day {
                store.asOf = last
                store.longAsOf = last
            }
            store.rescore(days: tape, preferReadySeries: !store.consumeSeriesPin())
            store.refreshVitalsCheck(days: repo.days)
            appearedWithoutNights = repo.days.isEmpty
        }
        // A synced night has to move the usuals without leaving and re-entering the tab.
        .onChangeCompat(of: repo.refreshSeq) { _ in
            if appearedWithoutNights, !repo.days.isEmpty {
                // The as-of night came from the store's demonstration tape: start from the newest real one.
                appearedWithoutNights = false
                store.jumpToNewestNight(days: days)
            }
            store.rescore(days: days)
            store.refreshVitalsCheck(days: repo.days)
        }
        .task {
            pipelineAvailable = Self.pipelineEnrolled()
            #if DEBUG
            if MonitorDemoHooks.sheet == "summary" {
                summary = ClinicianSummary(text: store.clinicianExportText(deviceId: repo.deviceId))
            }
            #endif
        }
        .sheet(item: $summary) { summary in
            ClinicianSummarySheet(text: summary.text)
        }
    }

    /// The scored night the Baseline rows read, as a date ("Tue 6 Oct").
    private var nightLabel: String? {
        guard let key = store.vitalsCheck?.night, let day = ChartDay.date(forKey: key) else { return nil }
        return ReadoutContent.dateLine(day, period: .day)
    }

    /// Share (built when picked, not on every render) and the owner's pipeline page.
    private var moreMenu: some View {
        Menu {
            Button {
                summary = ClinicianSummary(text: store.clinicianExportText(deviceId: repo.deviceId))
            } label: {
                Label("Share 7-day summary", systemImage: "square.and.arrow.up")
            }
            if pipelineAvailable {
                #if os(macOS)
                NavigationLink { PipelineDiagnosticsView() } label: {
                    Label("Pipeline diagnostics", systemImage: "server.rack")
                }
                #else
                NavigationLink(value: TabRoute.pipelineDiagnostics) {
                    Label("Pipeline diagnostics", systemImage: "server.rack")
                }
                #endif
            }
        } label: {
            HeaderControlGlyph(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    private static func pipelineEnrolled() -> Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-seed") { return true }
        #endif
        return CloudPushIdentityStore.current() != nil
    }
}

private struct ClinicianSummary: Identifiable {
    let id = UUID()
    let text: String
}

/// The 7-day clinician summary, shown before it is shared.
private struct ClinicianSummarySheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(StrandFont.footnote.monospaced())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NoopMetrics.cardPadding)
                    .background(NoopInsetSurface())
                    .padding(NoopMetrics.screenHPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("7-day summary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

// MARK: - Baseline vitals

/// The last scored night, one row per night vital against its own usual. Each row opens that vital's page.
private struct BaselineVitalsCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var store: BaselineStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var fahrenheit: Bool {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw) == .fahrenheit
    }

    var body: some View {
        NoopCard(padding: 0) {
            if !repo.loaded {
                // The real rows, redacted, until the first load lands: never "No nights" before it has.
                VStack(spacing: 0) {
                    ForEach(Array(BaselineStore.vitalsCheckSeries.enumerated()), id: \.offset) { index, series in
                        if index > 0 { NoopListDivider() }
                        BaselineVitalRow(name: store.shortTitle(for: series), usual: "Usual 00–00",
                                         value: "00", unit: series.planRow.unit, state: "In range", tone: .neutral)
                    }
                }
                .loadingPlaceholder(true)
            } else if let check = store.vitalsCheck {
                VStack(spacing: 0) {
                    ForEach(Array(check.vitals.enumerated()), id: \.element.id) { index, vital in
                        if index > 0 { NoopListDivider() }
                        MonitorLink(route: .baselineVital(vital.series.rawValue)) {
                            row(vital)
                        }
                        .buttonStyle(LiquidPressStyle())
                        .accessibilityHint("Opens \(vital.name) against your usual")
                    }
                }
            } else {
                Text(repo.days.isEmpty ? "No nights synced yet" : "No scored night yet")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight + 8, alignment: .leading)
            }
        }
    }

    private func row(_ vital: BaselineVitalsCheck.Vital) -> some View {
        let unit = MonitorLabels.unit(vital.unit, fahrenheit: fahrenheit)
        let display = { (v: Double) in MonitorLabels.displayValue(v, planUnit: vital.unit, fahrenheit: fahrenheit) }
        let usual: String? = {
            guard let lo = vital.bandLo, let hi = vital.bandHi else { return nil }
            return "Usual \(MonitorLabels.range(display(lo), display(hi), unit: unit))"
        }()
        return BaselineVitalRow(name: vital.name, usual: usual,
                                value: vital.value.map { MonitorLabels.number(display($0), unit: unit) },
                                unit: unit, state: MonitorLabels.vitalState(vital.state),
                                tone: MonitorLabels.vitalTone(vital.state))
    }
}

/// One night vital: name and its usual range, then the night's value and its state word.
private struct BaselineVitalRow: View {
    let name: String
    let usual: String?
    let value: String?
    let unit: String
    let state: String
    let tone: StrandTone

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(name)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let usual {
                    Text(usual)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value ?? "—")
                        .font(StrandFont.number(20))
                        .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    if value != nil {
                        Text(unit)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .lineLimit(1)
                .monospacedDigit()
                Text(state)
                    .font(StrandFont.footnote.weight(.medium))
                    .foregroundStyle(tone.color)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight + 8, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(value.map { "\($0) \(unit)" } ?? "no reading"), \(state)\(usual.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Daily log

/// The day's eight labels for Layer 1 (mood, activity, energy, ...). Opened from the Baseline vital page.
struct BaselineDayLogSheet: View {
    @EnvironmentObject var store: BaselineStore
    @Environment(\.dismiss) private var dismiss
    var days: [DailyMetric]
    @State private var mood: LBDayMood = .okay
    @State private var activeWindow: LBActiveWindow = .spread
    @State private var workout: LBWorkoutLoad = .none
    @State private var energy: LBDayEnergy = .steady
    @State private var demand: LBDayDemand = .usual
    @State private var alcohol = false
    @State private var travel = false
    @State private var feltIll = false
    @State private var extraMed = false
    @State private var scheduledMed: LBScheduledMedStatus = .unspecified
    @State private var sleepTypical = true
    @State private var dietTypical = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text(BaselinePlotScale.mediumDate(store.loggingDay))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    question("How was your mood today?") {
                        MonitorChipRow(LBDayMood.allCases, selection: $mood, label: { $0.displayLabel })
                    }
                    question("When were you most active?") {
                        MonitorChipRow(LBActiveWindow.allCases, selection: $activeWindow, label: { $0.displayLabel })
                    }
                    question("How hard was activity today?") {
                        MonitorChipRow(LBWorkoutLoad.allCases, selection: $workout, label: { $0.displayLabel })
                    }
                    question("How did energy feel through the day?") {
                        MonitorChipRow(LBDayEnergy.allCases, selection: $energy, label: { $0.displayLabel })
                    }
                    question("How demanding was the day besides the workout?") {
                        MonitorChipRow(LBDayDemand.allCases, selection: $demand, label: { $0.displayLabel })
                    }
                    question("Was eating typical for you?") {
                        MonitorChipRow([true, false], selection: $dietTypical, label: { $0 ? "Typical" : "Not typical" })
                    }
                    question("Anything that stood out?") {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            if store.activeStart != nil {
                                Text("Scheduled course")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                MonitorChipRow(LBScheduledMedStatus.allCases.filter { $0 != .unspecified } + [.unspecified],
                                               selection: $scheduledMed, label: { $0.displayLabel })
                            }
                            VStack(spacing: 0) {
                                toggle("Alcohol", $alcohol)
                                NoopListDivider(leadingInset: NoopMetrics.space3)
                                toggle("Travel", $travel)
                                NoopListDivider(leadingInset: NoopMetrics.space3)
                                toggle("Felt ill", $feltIll)
                                NoopListDivider(leadingInset: NoopMetrics.space3)
                                toggle("Another medication", $extraMed)
                            }
                            .background(NoopInsetSurface())
                        }
                    }
                    question("Was last night’s sleep typical for you?") {
                        MonitorChipRow([true, false], selection: $sleepTypical, label: { $0 ? "Typical" : "Not typical" })
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Daily log")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        store.showContextSheet = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let log = LBDayLog(workout: workout, alcohol: alcohol, travel: travel,
                                           feltIll: feltIll, sleepTypical: sleepTypical,
                                           dietTypical: dietTypical, extraMed: extraMed,
                                           scheduledMed: scheduledMed, mood: mood,
                                           activeWindow: activeWindow, energy: energy, demand: demand)
                        store.setDayLog(log, on: store.loggingDay, days: days)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let log = store.loggingLog {
                    mood = log.mood
                    activeWindow = log.activeWindow
                    workout = log.workout
                    energy = log.energy
                    demand = log.demand
                    alcohol = log.alcohol
                    travel = log.travel
                    feltIll = log.feltIll
                    extraMed = log.extraMed
                    scheduledMed = log.scheduledMed
                    sleepTypical = log.sleepTypical
                    dietTypical = log.dietTypical
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private func question<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .tint(StrandPalette.accent)
        .padding(.horizontal, NoopMetrics.space3)
        .frame(minHeight: NoopMetrics.minimumHitTarget + 4)
    }
}

/// A single-choice row of chips (the daily log and the alert note), three to a line, the selection in
/// the accent colour. Kit candidate (kit_issues: `NoopChip`).
struct MonitorChipRow<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var perRow: Int = 3

    init(_ items: [T], selection: Binding<T>, perRow: Int = 3, label: @escaping (T) -> String) {
        self.items = items
        self._selection = selection
        self.perRow = perRow
        self.label = label
    }

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: max(1, perRow)).map {
            Array(items[$0..<min($0 + max(1, perRow), items.count)])
        }
        VStack(spacing: NoopMetrics.space2) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(rows[i], id: \.self) { item in
                        MonitorChip(title: label(item), selected: selection == item) {
                            selection = item
                        }
                    }
                    if rows[i].count < perRow, rows.count > 1 {
                        ForEach(0..<(perRow - rows[i].count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
    }
}

/// One chip: an inset pill that fills with the accent when selected.
struct MonitorChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.subhead.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, NoopMetrics.space2)
                .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget)
                .background(
                    RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous)
                        .fill(selected ? StrandPalette.accent.opacity(0.18) : StrandPalette.surfaceInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous)
                        .strokeBorder(selected ? StrandPalette.accent : Color.clear, lineWidth: 1.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

func baselineOffColor(_ strength: Double) -> Color {
    let t = min(1, max(0, strength))
    #if canImport(UIKit)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    UIColor(StrandPalette.statusWarning).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    UIColor(StrandPalette.statusCritical).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                 blue: b1 + (b2 - b1) * t, opacity: a1 + (a2 - a1) * t)
    #elseif canImport(AppKit)
    guard let from = NSColor(StrandPalette.statusWarning).usingColorSpace(.sRGB),
          let to = NSColor(StrandPalette.statusCritical).usingColorSpace(.sRGB) else {
        return t < 0.5 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }
    return Color(red: from.redComponent + (to.redComponent - from.redComponent) * t,
                 green: from.greenComponent + (to.greenComponent - from.greenComponent) * t,
                 blue: from.blueComponent + (to.blueComponent - from.blueComponent) * t,
                 opacity: from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t)
    #else
    return t < 0.5 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    #endif
}

#Preview {
    BaselineMonitorView()
        .environmentObject(Repository(deviceId: "preview"))
        .environmentObject(BaselineStore())
        .environmentObject(NavRouter())
}
