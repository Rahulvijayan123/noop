import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore
import UserNotifications

// MARK: - OnboardingWizard
//
// A full-screen, paged onboarding + pairing flow for Nara: the flat surfaceBase canvas, one plain progress bar
// that fills as you advance, Back always available, and one forward CTA per step. Nothing loops except the
// scan sweep, and only while a Bluetooth scan is really running.
//
// Steps:
//  1 Welcome           — Nara + "your data stays on your phone unless you turn on cloud features"
//  2 What it does      — 3 calm value slides
//  3 Bluetooth priming — explain BEFORE the OS prompt
//  4 Wear & wake       — put your strap on, make sure it's charged
//  5 Scan              — radar sweep; auto-scans, Scan retries via model.scan()
//  6 Bonding           — a plain tick when live.bonded
//  7 Profile           — age / sex / weight / height bound to ProfileStore
//  8 Import (optional)  — WHOOP / Apple Health import from the wizard
//  9 Done              — "Your thread starts here." → onFinished()
//
// Presentation is wired centrally; this view only calls onFinished() when complete.

public struct OnboardingWizard: View {

    /// Called when the user finishes (or skips to the end of) onboarding.
    public var onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // NOTE: the root deliberately does NOT observe the fast-updating model/live/profile
    // env objects — doing so re-rendered the whole animated wizard on every HR tick and
    // caused flicker. Child steps observe what they need; a hidden BondWatcher (below)
    // handles the bond→celebration transition without re-rendering the root.

    private enum Step: Int, CaseIterable {
        case welcome, what, expectations, bluetooth, wear, scan, bonded, profile, importData, notifications, appearance, done

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }
    }

    @State private var step: Step = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top chrome: a small back affordance.
                topBar
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.top, NoopMetrics.space2)

                // The paged content.
                ZStack {
                    switch step {
                    case .welcome:    WelcomeStep()
                    case .what:       WhatItDoesStep()
                    case .expectations: ExpectationsStep()
                    case .bluetooth:  BluetoothStep()
                    case .wear:       WearStep()
                    case .scan:       ScanStep(advance: advance)
                    case .bonded:     BondedStep()
                    case .profile:    ProfileStep()
                    case .importData: ImportStep()
                    case .notifications: NotificationsStep()
                    case .appearance: AppearanceStep()
                    case .done:       DoneStep()
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                .transition(stepTransition)
                .id(step)                       // re-runs the transition per step
                .padding(.horizontal, NoopMetrics.screenHPadding)

                // Bottom: the progress bar + the forward CTA.
                bottomBar
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.top, NoopMetrics.space4)
                    .padding(.bottom, NoopMetrics.space4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Isolated live observation — a hidden watcher slides Scan → celebration on bond
        // without subscribing the whole wizard to per-tick updates.
        .background(BondWatcher(onBonded: handleBond))
    }

    private func handleBond() {
        if step == .scan { withAnimation(reduceMotion ? nil : StrandMotion.gentle) { step = .bonded } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if step.isFirst {
                Color.clear.frame(width: 64, height: NoopMetrics.minimumHitTarget)
            } else {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(StrandFont.subhead.weight(.medium))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(minHeight: NoopMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Spacer()
        }
    }

    // MARK: Bottom bar (the thread + CTA)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: NoopMetrics.space5) {
            ThreadProgress(progress: progress)
                .frame(height: 3)
                .frame(maxWidth: 620)
                .accessibilityElement()
                .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            NoopButton(LocalizedStringKey(ctaTitle), systemImage: ctaIcon, kind: .primary, fullWidth: true,
                       action: primaryAction)
                .frame(maxWidth: 620)
        }
    }

    private var progress: Double {
        guard Step.allCases.count > 1 else { return 1 }
        return Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    private var ctaTitle: String {
        switch step {
        case .welcome:    return String(localized: "Get started")
        case .what:       return String(localized: "Continue")
        case .expectations: return String(localized: "I understand")
        case .bluetooth:  return String(localized: "Continue")
        case .wear:       return String(localized: "I'm wearing it")
        case .scan:       return String(localized: "Continue")
        case .bonded:     return String(localized: "Continue")
        case .profile:    return String(localized: "Save and continue")
        case .importData: return String(localized: "Continue")
        case .notifications: return String(localized: "Continue")
        case .appearance: return String(localized: "Continue")
        case .done:       return String(localized: "Open Nara")
        }
    }

    private var ctaIcon: String? {
        switch step {
        case .done:    return "arrow.right"
        case .bonded:  return "checkmark"
        default:       return nil
        }
    }

    private func primaryAction() {
        if step.isLast {
            onFinished()
        } else {
            advance()
        }
    }

    // MARK: Navigation

    /// Leaving the Notifications step is the one point in onboarding where we actually ask the OS for
    /// notification permission — everything before this only explained why (the `NotificationsStep`
    /// card). Without this, NOOP never showed up under Settings → Notifications at all unless a user
    /// later found and enabled one of the opt-in automations (wind-down, battery, illness) buried in
    /// More → Alarms/Automations, each of which lazily requests on its own toggle. Mirrors the Android
    /// onboarding's `OnboardingPage.Notifications` step (`OnboardingScreen.kt`): request only if not
    /// already determined (so a re-run/upgrade doesn't re-prompt), and advance once the OS dialog is
    /// dismissed either way — the per-feature toggles still handle a later denial on their own.
    private func advance() {
        guard step != .notifications else {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else {
                    Task { @MainActor in advanceStep() }
                    return
                }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    Task { @MainActor in advanceStep() }
                }
            }
            return
        }
        advanceStep()
    }

    private func advanceStep() {
        guard let next = Step(rawValue: step.rawValue + 1) else { onFinished(); return }
        withAnimation(reduceMotion ? nil : StrandMotion.gentle) { step = next }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? nil : StrandMotion.gentle) { step = prev }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

/// Hidden, isolated observer — re-renders on live updates (it's just Color.clear, so no
/// visible cost) and fires `onBonded` when the strap bonds, keeping the main wizard body
/// out of the per-tick re-render path that caused flicker.
private struct BondWatcher: View {
    @EnvironmentObject private var live: LiveState
    let onBonded: () -> Void
    var body: some View {
        Color.clear.onChangeCompat(of: live.bonded) { newValue in if newValue { onBonded() } }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    var body: some View {
        StepShell {
            VStack(spacing: NoopMetrics.space6) {
                Spacer()
                BrandMark(size: 96)
                Text("Your data stays on your phone unless you turn on cloud features")
                    .font(StrandFont.brandDisplay(26))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Recovery, sleep and strain, read straight from your strap.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Spacer()
            }
        }
    }
}

// MARK: - Step 2 · What it does

private struct WhatItDoesStep: View {
    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        .init(icon: "circle.dashed.inset.filled",
              tint: StrandPalette.accent,
              title: String(localized: "See recovery, beautifully"),
              body: String(localized: "A signature ring distils HRV, resting heart rate and sleep into one calm read on whether to push or rest.")),
        .init(icon: "waveform.path.ecg",
              tint: StrandPalette.accent,
              title: String(localized: "Watch your heart, live"),
              body: String(localized: "Connect a WHOOP, a heart-rate strap or a gym machine and watch each beat in real time: heart rate, variability and zones as they happen. Already have history elsewhere? Import it from WHOOP, Apple Health, Oura, Fitbit or Garmin.")),
        .init(icon: "lock.shield",
              tint: StrandPalette.accent,
              title: String(localized: "Your data, on your phone"),
              body: String(localized: "Your readings are stored on \(Platform.deviceNounPhrase). Cloud features, such as Sana and cloud scoring, only run if you turn them on.")),
    ]

    var body: some View {
        StepShell(title: String(localized: "What Nara does")) {
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        SlideRow(slide: slide)
                    }
                }
            }
            .frame(maxWidth: 520)
        }
    }

    private struct SlideRow: View {
        let slide: Slide
        var body: some View {
            OnboardingInfoRow(icon: slide.icon, title: slide.title, message: slide.body)
        }
    }
}

// MARK: - Step 2.5 · What to expect (independent / experimental / 5-MG framing)

private struct ExpectationsStep: View {
    var body: some View {
        StepShell(title: String(localized: "What to expect")) {
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AppChangelog.expectations.enumerated()), id: \.element.id) { index, e in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        OnboardingInfoRow(icon: e.icon, title: e.title, message: e.body)
                    }
                    #if os(iOS)
                    // The iPhone-only reality: this is a sideloaded build, so set the re-sign + unlock
                    // expectation up front rather than letting it surprise people later (#222 / cert expiry).
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    OnboardingInfoRow(
                        icon: "iphone.gen3",
                        title: String(localized: "Installed outside the App Store"),
                        message: String(localized: "On iPhone this is a sideloaded build. Re-sign it about every 7 days on a free Apple ID (longer on a paid account). After your phone restarts, unlock it once so Nara can read and sync its data."))
                    #endif
                }
            }
            .frame(maxWidth: 520)
        }
    }
}

// MARK: - Step 3 · Bluetooth priming

private struct BluetoothStep: View {
    var body: some View {
        StepShell(title: String(localized: "A quick word before we connect"),
                  subtitle: String(localized: "\(Platform.deviceNoun) will ask for Bluetooth in a moment.")) {
            VStack(spacing: NoopMetrics.space6) {
                OnboardingHeroSymbol("wave.3.right")

                NoopCard(padding: 0) {
                    OnboardingInfoRow(
                        icon: "lock",
                        title: String(localized: "A local connection"),
                        message: String(localized: "Nara talks to your strap directly over Bluetooth Low Energy. There's no server in the middle of that connection."))
                }
                .frame(maxWidth: 480)

                Text("When the system prompt appears, choose Allow so Nara can find your strap.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
    }
}

// MARK: - Step 4 · Wear & wake

private struct WearStep: View {
    var body: some View {
        StepShell(title: String(localized: "Put your strap on")) {
            VStack(spacing: NoopMetrics.space6) {
                OnboardingHeroSymbol("applewatch.side.right")

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Wear it snug on your wrist or bicep, sensor against skin."))
                    Checkline(text: String(localized: "Give it a few minutes of charge if the battery is low."))
                    Checkline(text: String(localized: "Keep it within about a metre of \(Platform.deviceNounPhrase)."))
                }
                .frame(maxWidth: 440)
            }
        }
    }
}

// MARK: - Step 5 · Scan (radar sweep + reassurance)

private struct ScanStep: View {
    let advance: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var scanning = false
    @State private var showHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which strap to look for — shared with the Live screen via the same key.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop5mg.rawValue
    private var selectedModel: WhoopModel { WhoopModel.resolve(selectedModelRaw) }

    private static let bondedSubtitle = String(localized: "Bonded. You're set.")
    private static let scanSubtitle = String(localized: "Tap Scan and Nara will find your strap.")
    private static let whoop4Note = String(localized: "A WHOOP 4.0 only talks to one app at a time. If nothing's found, fully close the official WHOOP app, then Scan.")
    private static let whoop5Note = String(localized: "WHOOP 5.0/MG pairs with one app at a time. If nothing's found, unpair it in the official WHOOP app and fully close that app, then Scan.")

    var body: some View {
        StepShell(title: String(localized: "Find your strap"),
                  subtitle: live.bonded ? Self.bondedSubtitle : Self.scanSubtitle,
                  subtitleAlternatives: [Self.bondedSubtitle, Self.scanSubtitle]) {
            VStack(spacing: 24) {
                RadarSweep(active: scanning && !live.bonded, bonded: live.bonded)
                    .frame(width: 220, height: 220)

                statusLine

                if !live.bonded {
                    VStack(spacing: 8) {
                        Text("Which strap are you pairing?").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        SegmentedPillControl(
                            WhoopModel.allCases,
                            selection: Binding(
                                get: { selectedModel },
                                set: { restartScan(for: $0) }
                            ),
                            label: { $0.displayName }
                        )
                    }

                    // Proactive pairing guidance (#130): the strap bonds to one host at a time, so a scan
                    // here finds nothing while it's still paired in the official WHOOP app. Both models get
                    // a note, in one slot sized for the longer, so switching model never moves the Scan
                    // button underneath.
                    ReservedText(text: selectedModel == .whoop5mg ? Self.whoop5Note : Self.whoop4Note,
                                 alternatives: [Self.whoop4Note, Self.whoop5Note],
                                 font: StrandFont.footnote,
                                 alignment: .center,
                                 textAlignment: .center)
                        .frame(maxWidth: 360)

                    NoopButton(scanning ? "Scanning…" : "Scan", systemImage: "dot.radiowaves.left.and.right",
                               kind: .secondary) { startScan() }
                        .disabled(scanning)

                    // WHOOP is Nara's primary band, so onboarding leads with it — but it isn't required.
                    // Make that obvious so a non-WHOOP user doesn't feel stuck here: they can continue now
                    // and pair a heart-rate strap or import data afterwards (in Devices / Data sources).
                    Text("No WHOOP? You can still continue, then pair a heart-rate strap in Devices or import your history in Data sources.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)

                    // Below everything else, so opening it (or its arriving after a quiet beat) only grows the
                    // page downward and nothing above it moves.
                    DisclosureToggle(open: $showHelp, label: String(localized: "Don't see it?"))

                    if showHelp { reassurance }
                }
            }
        }
        .onDisappear { scanning = false }
    }

    private var statusLine: some View {
        // One pill at a time, always the same height, cross-fading as the state moves on.
        let state = live.bonded ? 0 : live.connected ? 1 : scanning ? 2 : 3
        return Group {
            switch state {
            case 0: StatePill("Connected", tone: .positive)
            case 1: StatePill("Connecting…", tone: .warning)
            case 2: StatePill("Searching", tone: .accent)
            default: StatePill("Ready to scan", tone: .neutral, showsDot: false)
            }
        }
        .id(state)
        .transition(.opacity)
        .animation(reduceMotion ? nil : PairingMotion.settle, value: state)
    }

    private func startScan(model scanModel: WhoopModel? = nil) {
        let modelToScan = scanModel ?? selectedModel
        scanning = true
        showHelp = false
        model.scan(model: modelToScan)
        // Surface the reassurance card if we haven't bonded after a calm beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !live.bonded {
                scanning = false
                withAnimation(reduceMotion ? nil : StrandMotion.gentle) { showHelp = true }
            }
        }
    }

    private func restartScan(for newModel: WhoopModel) {
        selectedModelRaw = newModel.rawValue
        guard !live.bonded else { return }
        model.disconnect()
        startScan(model: newModel)
    }

    // The calm, never-alarmist "can't find it" card.
    private var reassurance: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Don't see it? That's normal.")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                Text("WHOOP straps don't appear in your \(Platform.deviceNoun)'s Bluetooth settings. They advertise on a custom profile that only apps like Nara can find, so there's nothing to pair there, and you shouldn't try.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Checkline(text: String(localized: "It's charged and worn. The sensor needs skin contact to wake."))
                    Checkline(text: String(localized: "It isn't held by the WHOOP phone app. Only one host at a time: close the app or turn off its Bluetooth."))
                    Checkline(text: String(localized: "It's within about a metre of \(Platform.deviceNounPhrase)."))
                }

                NoopButton("Try again", systemImage: "arrow.clockwise", kind: .secondary, action: retry)
            }
        }
        .frame(maxWidth: 480)
        .transition(.opacity)
    }

    private func retry() {
        withAnimation(reduceMotion ? nil : StrandMotion.gentle) { showHelp = false }
        startScan()
    }
}

// MARK: - Step 6 · Bonding celebration

private struct BondedStep: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        StepShell {
            VStack(spacing: NoopMetrics.space6) {
                Spacer()
                // A plain tick in a ring-sized well: no score ring, which would read as a score.
                ZStack {
                    Circle()
                        .fill(StrandPalette.surfaceInset)
                    Circle()
                        .strokeBorder(StrandPalette.statusPositive, lineWidth: 3)
                    Image(systemName: "checkmark")
                        .font(StrandFont.icon(.hero).weight(.semibold))
                        .foregroundStyle(StrandPalette.statusPositive)
                }
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)

                VStack(spacing: NoopMetrics.space2) {
                    Text("You're connected.")
                        .font(StrandFont.brandDisplay(28))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(batteryLine)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var batteryLine: String {
        if let pct = live.batteryPct {
            return String(localized: "Your strap is bonded · \(Int(pct)) % battery.")
        }
        return String(localized: "Your strap is bonded and ready to stream.")
    }
}

// MARK: - Step 7 · Profile

private struct ProfileStep: View {
    @EnvironmentObject private var profile: ProfileStore

    // The stored profile is always SI; Nara shows US units (pounds, feet and inches) everywhere.
    private let unitSystem = UnitSystem.imperial

    private let sexes: [(String, String)] = [
        ("male", String(localized: "Male")), ("female", String(localized: "Female")),
        ("nonbinary", String(localized: "Other"))
    ]

    var body: some View {
        StepShell(title: String(localized: "About you"),
                  subtitle: String(localized: "So your zones, calories and baselines are accurate.")) {
            VStack(spacing: 16) {
                NoopCard {
                    VStack(spacing: NoopMetrics.space4) {
                        // #146: capture a date of birth so age advances on its own instead of going stale.
                        DatePicker(selection: $profile.dateOfBirth,
                                   in: ProfileStore.dateOfBirthRange,
                                   displayedComponents: .date) {
                            FieldRow(label: String(localized: "Date of birth"),
                                     value: String(localized: "\(profile.age) yrs"))
                        }
                        .tint(StrandPalette.accent)

                        Divider().overlay(StrandPalette.hairline)

                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Sex").strandLabel()
                            SegmentedPillControl(sexes.map(\.0), selection: $profile.sex, fillsAvailableWidth: true) { key in
                                sexes.first { $0.0 == key }?.1 ?? key
                            }
                            .accessibilityLabel("Sex")
                        }

                        Divider().overlay(StrandPalette.hairline)

                        // Steppers, not sliders — matches the Age row above and the macOS Settings
                        // profile editor (same ranges/steps), so every numeric profile field is
                        // consistent across onboarding and Settings on both platforms.
                        Stepper(value: $profile.weightKg, in: 30...250, step: 0.5) {
                            FieldRow(label: String(localized: "Weight"),
                                     value: UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem))
                        }

                        Divider().overlay(StrandPalette.hairline)

                        Stepper(value: $profile.heightCm, in: 120...230, step: 1) {
                            FieldRow(label: String(localized: "Height"),
                                     value: UnitFormatter.heightFromCentimeters(profile.heightCm, system: unitSystem))
                        }
                    }
                }

                Text("Estimated max heart rate · \(profile.hrMax) bpm")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

// MARK: - Step 8 · Import (optional)

private struct ImportStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        StepShell(title: String(localized: "Bring your history"),
                  subtitle: String(localized: "Optional: import now, or continue and use Data sources later.")) {
            VStack(spacing: NoopMetrics.space4) {
                NoopCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { presentImporter(.whoop) } label: {
                            NoopListRow(icon: "tray.and.arrow.down", iconColor: StrandPalette.accent,
                                        title: model.isImporting(.whoop) ? "Importing…" : "Import WHOOP export",
                                        subtitle: String(localized: "Recovery, strain, sleep and workouts"))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.hasActiveImport)
                        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                        Button { presentImporter(.appleHealth) } label: {
                            NoopListRow(icon: "heart", iconColor: StrandPalette.accent,
                                        title: model.isImporting(.appleHealth) ? "Working…" : "Import Apple Health export",
                                        subtitle: String(localized: "Heart rate, HRV, sleep, steps and more"))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.hasActiveImport)
                    }
                }
                .frame(maxWidth: 480)

                if model.hasActiveImport {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StrandPalette.accent)
                }

                // Show the summary for the source the user last imported, styled off the typed
                // failure flag (not a substring match) so real errors read as warnings.
                if let summary = lastSummary {
                    Text(summary)
                        .font(StrandFont.subhead)
                        .foregroundStyle(model.importFailed(importKind) ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    /// The AppModel source kind matching the last-chosen import target.
    private var importKind: DataSourceImportKind {
        switch importTarget {
        case .whoop: return .whoop
        case .appleHealth: return .appleHealth
        }
    }

    /// The summary for the source the user last imported in this step.
    private var lastSummary: String? {
        switch importTarget {
        case .whoop: return model.whoopImportSummary
        case .appleHealth: return model.appleHealthImportSummary
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            // See DataSourcesView: `.folder` is a macOS-only affordance (pick an unzipped export
            // directory). On iOS it greys out the .zip in the Files picker (issue #179), so iOS
            // offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            }
        }
    }
}

// MARK: - Step 9 · Notifications (wrist alerts priming)

private struct NotificationsStep: View {
    var body: some View {
        StepShell(title: String(localized: "Stay in the loop"),
                  subtitle: String(localized: "Nara can tap your wrist when it needs you.")) {
            VStack(spacing: NoopMetrics.space6) {
                OnboardingHeroSymbol("bell.badge")

                #if os(iOS)
                // iOS gives an app no way to observe *other* apps' notifications, and the per-app picker
                // behind it is NSWorkspace-based (macOS-only). So drop the cross-app relay claim here and
                // keep only what iOS genuinely does: Nara's own strain nudges + smart alarm buzz the strap
                // directly over BLE.
                NoopCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        OnboardingInfoRow(
                            icon: "applewatch.radiowaves.left.and.right",
                            title: String(localized: "A buzz, not a banner"),
                            message: String(localized: "Strain nudges and your smart alarm tap your strap, so an alert lands on your wrist instead of your screen."))
                    }
                }
                .frame(maxWidth: 480)
                #else
                NoopCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        OnboardingInfoRow(
                            icon: "applewatch.radiowaves.left.and.right",
                            title: String(localized: "A buzz, not a banner"),
                            message: String(localized: "When the \(Platform.deviceNoun) apps you choose send a notification, Nara taps your strap. Pick which apps reach your wrist in Settings → Notifications."))
                        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                        OnboardingInfoRow(
                            icon: "alarm",
                            title: String(localized: "Nudges and alarms"),
                            message: String(localized: "Strain nudges and your smart alarm tap your wrist the same way."))
                    }
                }
                .frame(maxWidth: 480)
                #endif
            }
        }
    }
}

// MARK: - Step 10 · Done

private struct DoneStep: View {
    var body: some View {
        StepShell {
            VStack(spacing: NoopMetrics.space6) {
                Spacer()
                OnboardingHeroSymbol("point.topleft.down.curvedto.point.bottomright.up")
                VStack(spacing: NoopMetrics.space2) {
                    Text("Your thread starts here.")
                        .font(StrandFont.brandDisplay(28))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Welcome to Nara.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Step shell (shared layout for each page)

/// Lets a brand-new user pick the app's look up front (and learn it's changeable) — the same
/// System / Light / Dark setting that lives in Settings → Appearance. Selecting re-themes the whole
/// app live (the shared `@AppStorage(AppearanceMode.storageKey)` drives `preferredColorScheme`), so
/// the wizard itself IS the preview.
private struct AppearanceStep: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    private var binding: Binding<AppearanceMode> {
        Binding(get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }
    var body: some View {
        StepShell(title: String(localized: "Make it yours"),
                  subtitle: String(localized: "You can change this in Settings.")) {
            VStack(spacing: NoopMetrics.space6) {
                OnboardingHeroSymbol("circle.lefthalf.filled")
                SegmentedPillControl(AppearanceMode.allCases, selection: binding) { $0.label }
                    .frame(maxWidth: 320)
                Text("System follows your \(Platform.deviceNoun)'s light or dark setting.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
        }
    }
}

private struct StepShell<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    /// Other lines the subtitle can turn into. When given, the subtitle's slot is as tall as the longest
    /// of them, so the content below does not move when the wording does.
    var subtitleAlternatives: [String] = []
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: NoopMetrics.space5) {
                if title != nil || subtitle != nil {
                    VStack(spacing: NoopMetrics.space2) {
                        if let title {
                            Text(title)
                                .font(StrandFont.brandDisplay(27, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.center)
                        }
                        if let subtitle {
                            if subtitleAlternatives.isEmpty {
                                Text(subtitle)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                ReservedText(text: subtitle,
                                             alternatives: subtitleAlternatives,
                                             font: StrandFont.body,
                                             alignment: .center,
                                             textAlignment: .center)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                content()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NoopMetrics.space6)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. First-run wizard, every step routes
        // through this one shell, so a single fix here covers the whole onboarding flow.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
    }
}

// MARK: - Radar sweep

private struct RadarSweep: View {
    var active: Bool
    var bonded: Bool
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Concentric rings.
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(StrandPalette.hairline.opacity(0.7), lineWidth: 1)
                        .frame(width: size * Double(i) / 3, height: size * Double(i) / 3)
                }
                // Cross hairs.
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                    p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
                }
                .stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 1)

                // The sweeping wedge.
                if active {
                    sweepWedge(size: size)
                        .rotationEffect(.degrees(angle))
                }

                // Center node — accent while searching, mint when bonded.
                Circle()
                    .fill(bonded ? StrandPalette.statusPositive : StrandPalette.accent)
                    .frame(width: 14, height: 14)

                // A discovered "blip" once bonded.
                if bonded {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 12, height: 12)
                        .position(x: size * 0.70, y: size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
        }
        .onAppear {
            if active { startSweep() }
        }
        .onChangeCompat(of: active) { isActive in
            if isActive { startSweep() }
        }
    }

    private func sweepWedge(size: CGFloat) -> some View {
        let radius = size / 2
        return AngularGradient(
            gradient: Gradient(colors: [StrandPalette.accent.opacity(0.0),
                                        StrandPalette.accent.opacity(0.45)]),
            center: .center,
            startAngle: .degrees(-50),
            endAngle: .degrees(0)
        )
        .mask(
            Path { p in
                let c = CGPoint(x: radius, y: radius)
                p.move(to: c)
                p.addArc(center: c, radius: radius,
                         startAngle: .degrees(-50), endAngle: .degrees(0), clockwise: false)
                p.closeSubpath()
            }
        )
        .frame(width: size, height: size)
    }

    private func startSweep() {
        // Reduce Motion: keep the wedge still (the static rings/crosshairs/blip
        // still convey "searching" / "found") instead of spinning forever.
        guard !poseStill else { return }
        angle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

// MARK: - The bottom "thread" progress

private struct ThreadProgress: View {
    var progress: Double           // 0...1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StrandPalette.hairline)
                Capsule()
                    .fill(StrandPalette.accent)
                    .frame(width: max(6, geo.size.width * progress))
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
        }
    }
}

// MARK: - Reusable pieces

/// One explained point inside a list card: an accent symbol, a title and a sentence. No icon tile.
private struct OnboardingInfoRow: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.cardPadding)
        .accessibilityElement(children: .combine)
    }
}

/// The one large symbol a step leads with, static, in a quiet inset well.
private struct OnboardingHeroSymbol: View {
    private let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name)
            .font(StrandFont.icon(.hero))
            .foregroundStyle(StrandPalette.accent)
            .frame(width: 96, height: 96)
            .background(Circle().fill(StrandPalette.surfaceInset))
            .accessibilityHidden(true)
    }
}

private struct Checkline: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.statusPositive)
                .padding(.top, 1)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct DisclosureToggle: View {
    @Binding var open: Bool
    let label: String
    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                Text(label)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#if DEBUG
/// `--demo-screen onboardingscan`: the "Find your strap" step on its own, so it can be captured in a simulator
/// that has no strap. `--demo-strap-state` seeds the link the same way as for Pair & connect.
struct OnboardingScanDemoScreen: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        ScanStep(advance: { })
            .task {
                for _ in 0..<3 {
                    StrapDemoSeed.apply(StrapDemoSeed.requestedState, to: live)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
    }
}

private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .frame(width: 1100, height: 780)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
