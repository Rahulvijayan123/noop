import SwiftUI
import StrandDesign

/// The strap's alerts, gestures, haptics and optional health reads, one Settings page per topic. Every
/// control writes the same preference key the engine that acts on it reads; this screen holds no logic.
/// The macOS sidebar shows every page's sections on one screen (`page == nil`).
struct AutomationsView: View {
    enum Page: CaseIterable {
        /// Things that buzz or notify you: wrist alerts, move reminder, battery, Effort, illness.
        case alerts
        /// What the strap's double-tap does, and Shortcuts run when it comes off or goes on.
        case shortcuts
        /// In-session cues and haptic coaching.
        case haptics
        /// Optional reads of nightly signals: cycle awareness and Rhythm.
        case healthInsights

        var title: LocalizedStringKey {
            switch self {
            case .alerts: return "Alerts"
            case .shortcuts: return "Double-tap & wear"
            case .haptics: return "Haptics"
            case .healthInsights: return "Health insights"
            }
        }
    }

    /// nil shows every page.
    var page: Page? = nil

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    // PERF: this screen does NOT observe `LiveState`; the one live pixel (the bond pill on the double-tap
    // page) is the `BondStatePill` leaf, so a ~1 Hz strap tick re-renders just that pill.

    /// v5 cycle-awareness opt-in (default OFF — the most sensitive health category, manual-first).
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleAwareness = false
    /// #hide-cycle: the user's "not for me" opt-out (never age-based). Kept here so the offer can be
    /// brought back after it is hidden from Today and Health.
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false
    /// v5 Rhythm experimental gate (the screen still shows its own consent clickwrap when opened).
    @AppStorage(RhythmConsent.enabledKey) private var rhythmEnabled = false
    /// Inactivity reminder (#419). The buzz fires after each completed history sync
    /// (ActivityContextCoordinator → StandReminderEngine); this screen only edits the prefs it reads.
    @StateObject private var inactivity = InactivityPrefs()
    #if os(iOS)
    /// Wrist-alerts master gate (PR #572). The Notifications screen that owns this key on macOS is not in
    /// the iOS target, so iPhone binds the same raw key here. Default OFF, matching that store.
    @AppStorage(AppModel.wristAlertsMasterKey) private var wristAlertsMaster = false
    #endif

    // #haptics (#1115): per-event toggles for the in-session strap buzzes. Default ON (opt-out): they are
    // feedback to a feature you started. Same keys the buzz sites read via HapticPrefs.
    @AppStorage(HapticPrefs.breathing) private var breathingHaptic = true
    @AppStorage(HapticPrefs.intervals) private var intervalsHaptic = true
    @AppStorage(HapticPrefs.liftRest) private var liftRestHaptic = true
    @AppStorage(HapticPrefs.liveSession) private var liveSessionHaptic = true
    @AppStorage(HapticPrefs.workout) private var workoutHaptic = true

    /// Whether the cycle-awareness opt-in is offered for this profile (#801), the same gate the Health
    /// opt-in card uses.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies }

    var body: some View {
        ScreenScaffold(title: page?.title ?? "Automations") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ForEach(Self.pages(for: page), id: \.self) { page in
                    switch page {
                    case .alerts: alertsSections
                    case .shortcuts: shortcutsSections
                    case .haptics: hapticsSections
                    case .healthInsights: healthInsightsSections
                    }
                }
            }
        }
    }

    /// The pages a screen shows: one, or all of them in order.
    static func pages(for page: Page?) -> [Page] {
        page.map { [$0] } ?? Page.allCases
    }

    // MARK: - Alerts

    @ViewBuilder
    private var alertsSections: some View {
        #if os(iOS)
        SettingsGroup(footer: "Lets move reminders buzz your strap, and posts them as notifications.") {
            SettingsToggleRow("Wrist alerts", isOn: $wristAlertsMaster)
                .accessibilityIdentifier("automations.wristAlerts")
        }
        #endif
        moveReminderGroup
        SettingsGroup("Notifications") {
            SettingsToggleRow("Strap battery", detail: "When the battery is low, and when it's full.",
                              isOn: $behavior.batteryAlerts)
                .accessibilityIdentifier("automations.battery")
                .onChangeCompat(of: behavior.batteryAlerts) { on in
                    if on { BatteryNotifier.requestAuthorization() }
                }
            if behavior.batteryAlerts {
                SettingsDivider()
                SettingsToggleRow("Early battery warning", detail: "When about a day of battery is left.",
                                  isOn: $behavior.batteryPredictiveAlerts)
            }
            SettingsDivider()
            SettingsToggleRow("Effort target", detail: "Once a day, when Effort reaches today's target.",
                              isOn: $behavior.strainTargetNudge)
                .accessibilityIdentifier("automations.effortTarget")
                .onChangeCompat(of: behavior.strainTargetNudge) { on in
                    guard on else { return }
                    StrainTargetNotifier.requestAuthorization()
                    // The repo.$days sink only fires on data changes, so if today's target is already
                    // reached, evaluate now rather than waiting for the next refresh.
                    model.evaluateStrainTarget()
                }
            SettingsDivider()
            SettingsToggleRow("Illness signs",
                              detail: "When resting heart rate, HRV, temperature and breathing drift together. Needs 14 days of data. Not a diagnosis.",
                              isOn: $behavior.illnessWatch)
                .accessibilityIdentifier("automations.illness")
                .onChangeCompat(of: behavior.illnessWatch) { on in
                    model.reevaluateIllness()
                    if on { IllnessNotifier.requestAuthorization() }
                }
        }
    }

    private var moveReminderGroup: some View {
        SettingsGroup("Move reminder") {
            SettingsToggleRow("Move reminder", detail: "A buzz when you've been still too long.",
                              isOn: $inactivity.enabled)
                .accessibilityIdentifier("automations.moveReminder")
            if inactivity.enabled {
                #if os(iOS)
                if !wristAlertsMaster {
                    SettingsNote("Turn on Wrist alerts for this to buzz.", tone: StrandPalette.statusWarning)
                }
                #endif
                SettingsDivider()
                SettingsStepperRow(label: "Still for", value: $inactivity.thresholdMinutes,
                                   range: 15...120, step: 5, format: Self.minutesLabel)
                SettingsDivider()
                SettingsStepperRow(label: "Remind again after", value: $inactivity.reNudgeMinutes,
                                   range: 15...120, step: 15, format: Self.minutesLabel)
                SettingsDivider()
                SettingsStepperRow(label: "Buzz strength", value: $inactivity.buzzLoops,
                                   range: 1...4, step: 1, format: { "\($0)×" })
                SettingsDivider()
                SettingsToggleRow("Only during set hours", isOn: $inactivity.activeHoursEnabled)
                if inactivity.activeHoursEnabled {
                    SettingsDivider()
                    activeHoursRow
                }
            }
        }
    }

    private var activeHoursRow: some View {
        HStack(spacing: NoopMetrics.space3) {
            Text("Hours").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            DatePicker("", selection: activeStartBinding, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.compact)
                .accessibilityLabel("Reminder hours start")
            Text("to").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            DatePicker("", selection: activeEndBinding, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.compact)
                .accessibilityLabel("Reminder hours end")
        }
        .padding(.horizontal, NoopMetrics.space4)
        .frame(minHeight: 52)
    }

    private static func minutesLabel(_ value: Int) -> String { String(localized: "\(value) min") }

    private var activeStartBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeStartMinutes) },
                set: { inactivity.activeStartMinutes = Self.minutes(from: $0) })
    }
    private var activeEndBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeEndMinutes) },
                set: { inactivity.activeEndMinutes = Self.minutes(from: $0) })
    }

    // MARK: - Double-tap & wear

    @ViewBuilder
    private var shortcutsSections: some View {
        SettingsGroup("Double-tap") {
            HStack(spacing: NoopMetrics.space3) {
                Text("Action").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                Picker("Action", selection: $behavior.doubleTapAction) {
                    ForEach(Self.doubleTapOptions) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .tint(StrandPalette.accent)
                .accessibilityIdentifier("automations.doubleTapAction")
            }
            .padding(.horizontal, NoopMetrics.space4)
            .frame(minHeight: 52)
            if behavior.doubleTapAction == .runShortcut {
                SettingsDivider()
                shortcutField("Shortcut name", text: $behavior.doubleTapShortcut)
            }
            SettingsDivider()
            HStack(spacing: NoopMetrics.space3) {
                Button {
                    model.runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
                } label: {
                    Text("Try it")
                        .font(StrandFont.body)
                        .foregroundStyle(behavior.doubleTapAction == .none ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(SettingsRowStyle())
                .disabled(behavior.doubleTapAction == .none)
                Spacer(minLength: 0)
                BondStatePill()
            }
            .padding(.horizontal, NoopMetrics.space4)
            .frame(minHeight: 52)
            if !model.moments.isEmpty {
                SettingsDivider()
                momentsView
            }
        }
        SettingsGroup("Wear", footer: "Runs a Shortcut when the strap comes off or goes back on.") {
            #if os(macOS)
            SettingsToggleRow("Lock the Mac when I take the strap off", isOn: $behavior.autoLockOnWristOff)
            SettingsDivider()
            #endif
            shortcutField("When taken off", text: $behavior.wristOffShortcut)
            SettingsDivider()
            shortcutField("When put back on", text: $behavior.wristOnShortcut)
        }
    }

    /// A Shortcut name entry: label left, the field right.
    private func shortcutField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            TextField("Shortcut name", text: text)
                .multilineTextAlignment(.trailing)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .autocorrectionDisabled()
                .frame(maxWidth: 200)
                .accessibilityLabel(Text(label))
        }
        .padding(.horizontal, NoopMetrics.space4)
        .frame(minHeight: 52)
    }

    private var momentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent moments").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button("Clear") {
                    model.moments.removeAll()
                    UserDefaults.standard.removeObject(forKey: "moments")
                }
                .buttonStyle(.plain).font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            ForEach(Array(model.moments.suffix(5).reversed().enumerated()), id: \.offset) { _, d in
                Text(Self.momentFormatter.string(from: d))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
    }

    private static let momentFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        // Keep the "EEE d MMM ·" layout but honor the device's 12-/24-hour clock (#337): the "j"
        // template resolves to a 12-hour pattern (contains "a") only where the user prefers it.
        let uses24h = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: AppLanguage.activeLocale) ?? "H").contains("a")
        f.dateFormat = "EEE d MMM · " + (uses24h ? "HH:mm" : "h:mm a")
        return f
    }()

    /// Double-tap actions offered in the picker. A third-party app can't lock an iPhone, so "Lock" is
    /// dropped there.
    static var doubleTapOptions: [MacActionKind] {
        #if os(iOS)
        MacActionKind.allCases.filter { $0 != .lockScreen }
        #else
        MacActionKind.allCases
        #endif
    }

    // MARK: - Haptics

    @ViewBuilder
    private var hapticsSections: some View {
        SettingsGroup("During sessions") {
            SettingsToggleRow("Breathing pacer", isOn: $breathingHaptic)
                .accessibilityIdentifier("automations.breathingHaptic")
            SettingsDivider()
            SettingsToggleRow("Interval timer", isOn: $intervalsHaptic)
            SettingsDivider()
            SettingsToggleRow("Lift rest timer", isOn: $liftRestHaptic)
                .accessibilityIdentifier("automations.liftRestHaptic")
            SettingsDivider()
            SettingsToggleRow("Live session cues", isOn: $liveSessionHaptic)
            SettingsDivider()
            SettingsToggleRow("Workout start and end", isOn: $workoutHaptic)
        }
        SettingsGroup("Coaching") {
            SettingsToggleRow("Heart-rate zones", detail: "A buzz in your top zone, and again once you're back down.",
                              isOn: $behavior.zoneCoaching)
                .accessibilityIdentifier("automations.zoneCoaching")
            SettingsDivider()
            // v5 L3 closed-loop check-in (master + sub toggles). Default OFF, manual-first. The keys
            // mirror BiofeedbackPrefs, which the central detector (AppModel.evaluateStress) reads.
            SettingsToggleRow("Stress check-ins", detail: "Offers a one-minute breath when your HRV dips while you're still.",
                              isOn: $behavior.stressCheckIn)
                .accessibilityIdentifier("automations.stressCheckIn")
            if behavior.stressCheckIn {
                SettingsDivider()
                SettingsToggleRow("Start automatically", isOn: $behavior.stressAutoNudge)
                SettingsDivider()
                SettingsToggleRow("Quiet overnight", detail: "10 pm to 7 am.", isOn: $behavior.stressQuietHours)
                SettingsDivider()
                SettingsToggleRow("Use my resonance pace", isOn: $behavior.stressUseResonancePace)
            }
        }
    }

    // MARK: - Health insights

    private var healthInsightsSections: some View {
        SettingsGroup(footer: "Read from your nightly signals on \(Platform.deviceNounPhrase). For awareness only, not a diagnosis.") {
            // #801: cycle awareness reads the MENSTRUAL temperature shift, so it is only offered to profiles
            // it applies to, gated the same way as the Health opt-in card.
            if cycleOptInApplies {
                // #hide-cycle: the master visibility control — a USER opt-out, never age-based. Turning it
                // off hides the offer on Today + Health AND stops active tracking; turning it back on
                // re-offers it.
                SettingsToggleRow("Show cycle awareness",
                                  isOn: Binding(get: { !cycleHidden },
                                                set: { show in
                                                    cycleHidden = !show
                                                    if !show {
                                                        cycleAwareness = false
                                                        model.cycleAwarenessEnabled = false
                                                        Task { await model.refreshV5Signals() }
                                                    }
                                                }))
                    .accessibilityIdentifier("automations.showCycle")
                if !cycleHidden {
                    SettingsDivider()
                    SettingsToggleRow("Cycle awareness", detail: "A cycle phase from your nightly skin temperature.",
                                      isOn: $cycleAwareness)
                        .accessibilityIdentifier("automations.cycle")
                        .onChangeCompat(of: cycleAwareness) { on in
                            model.cycleAwarenessEnabled = on
                            Task { await model.refreshV5Signals() }
                        }
                }
                SettingsDivider()
            }
            // The Rhythm screen itself opens from the Sleep tab's body-clock dial.
            SettingsToggleRow("Rhythm", detail: "An experimental view of your beat-to-beat heart timing. Not an ECG.",
                              isOn: $rhythmEnabled)
                .accessibilityIdentifier("automations.rhythm")
        }
    }

    // MARK: - Helpers

    // `date(fromMinutes:)` / `minutes(from:)`: the move-reminder hours pickers use them.
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// The strap bond-status pill on the double-tap page. It owns its OWN `@EnvironmentObject live` so a
/// ~1 Hz strap publish re-renders only this pill, not the whole page.
private struct BondStatePill: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        StatePill(live.bonded ? "Strap connected" : "Strap not connected",
                  tone: live.bonded ? .positive : .warning, showsDot: true)
    }
}
