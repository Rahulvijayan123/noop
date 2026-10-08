import SwiftUI
import StrandDesign
import StrandAnalytics

// ActivityCalibrationView.swift - Test Centre's guided activity ground-truth capture.
//
// Drives ActivityCalibrationSessionRunner (the pure, closure-injected state machine in
// Strand/Collect/ActivityCalibrationSession.swift) against the live BLE/live state, and turns each
// completed step into an ActivityGroundTruthLabel persisted through ActivityGroundTruthStore.shared.
//
// Everything on screen is read from the runner's published phase and its deadlines: the words
// ("Hold", "Get ready", "Now") change in the same tick as the buzz, and the numbers count down to the
// same instants the runner acts on. The strap buzzes only for "move now" (one) and "activity done"
// (three); the phone's Taptic Engine mirrors both on iOS.

struct ActivityCalibrationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        ActivityCalibrationPage(model: model, live: live)
    }
}

/// The actual page. Receives `model`/`live` as plain properties so the runner (created once, in
/// `init`) can capture them - `@EnvironmentObject` is not readable before the view is inserted.
/// Same split as `StrapConnectionView`/`StrapConnectionPage`.
private struct ActivityCalibrationPage: View {
    let model: AppModel
    let live: LiveState

    @StateObject private var runner: ActivityCalibrationSessionRunner
    /// The guided session uuid that becomes every label's `sessionId` and the label-key middle.
    /// Rotated on each `begin`, so a stopped-and-restarted run is its own evaluation session.
    @State private var sessionID = CalibrationSessionID()
    /// Feedback counters fed by the `onBout` closure (a reference box the view observes).
    @StateObject private var status = CalibrationStatus()
    /// The last personal-profile fit for this account and strap, and whether one is running now.
    @State private var personalRecord: ActivityPersonalProfileStore.Record?
    @State private var personalScoped = true
    @State private var refitting = false

    @Environment(\.scenePhase) private var scenePhase

    /// 10 Hz state-machine tick + gate re-check, so a cue fires within 0.1 s of its deadline. Both
    /// calls are no-ops when no session is running.
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    init(model: AppModel, live: LiveState) {
        self.model = model
        self.live = live
        let runner = ActivityCalibrationSessionRunner(
            protocol: ActivityCalibrationProtocols.current,
            deviceId: nil,   // the label builder reads model.ble.deviceId at save time
            gate: { ActivityCalibrationPage.gateStatus(model: model, live: live) },
            applyMode: { mode in model.ble.setActivityImuCaptureMode(mode) },
            haptic: { cue in ActivityCalibrationPage.fireCue(cue, model: model) },
            now: { Date() })
        _runner = StateObject(wrappedValue: runner)
    }

    /// `@StateObject`/`@State` values read in `init` are throwaway copies, so the bout sink is wired once
    /// the page is installed and reads the live counters and session id.
    private func wireBoutSink() {
        let model = model, sessionID = sessionID, status = status
        runner.onBout = { bout in
            ActivityCalibrationPage.persist(bout: bout, model: model, sessionID: sessionID)
            status.savedCount += 1
            status.lastSavedAt = Date()
        }
    }

    private var protocolModel: ActivityCalibrationProtocolModel { runner.model }

    private func holdScreenAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    var body: some View {
        ScreenScaffold(
            title: "Activity calibration",
            subtitle: "Teach Nara how you sit, stand and lie down."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                personalCard
                liveCard
                controls
                savedSummary
            }
        }
        .onAppear {
            wireBoutSink()
            refreshPersonal(refit: true)
        }
        .onReceive(ticker) { _ in
            runner.tick()
            runner.refreshGate()
        }
        .onDisappear { holdScreenAwake(false) }
        .onChangeCompat(of: scenePhase) { phase in
            // A backgrounded scene cannot keep timing honest: stop the session (previous IMU mode
            // restored, durable marker cleared). A banner or Control Center only makes the scene
            // inactive, which does not stop the clock.
            if phase == .background { runner.cancel() }
        }
        .onChangeCompat(of: runner.phase) { phase in
            holdScreenAwake(runner.isRunning)
            switch phase {
            case .finished, .cancelled, .gate:
                if status.savedCount > 0 {
                    Task { try? await ActivityGroundTruthCloudSync().pushPending() }
                    refreshPersonal(refit: true)
                }
            default:
                break
            }
        }
    }

    // MARK: - Personal calibration

    /// Show the stored fit at once; with `refit`, run a fit (a no-op when nothing changed) and show its result.
    private func refreshPersonal(refit: Bool) {
        let store = ActivityPersonalProfileStore.shared
        personalScoped = store.currentScope != nil
        personalRecord = store.record()
        guard refit, personalScoped, !refitting else { return }
        refitting = true
        Task { @MainActor in
            let record = await model.refitActivityPersonalProfile()
            personalRecord = record ?? store.record()
            refitting = false
        }
    }

    private var personalCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Personal calibration").font(StrandFont.overline).foregroundStyle(StrandPalette.textSecondary)
                Text(personalHeadline)
                    .font(StrandFont.subhead)
                    .foregroundStyle(personalRecord?.result.status == .adopted
                                     ? StrandPalette.statusPositive : StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = personalDetail {
                    Text(detail)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if refitting {
                    Text("Checking your runs...")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var personalHeadline: String {
        guard personalScoped else { return "Off: link the strap to your account to personalise it." }
        guard let result = personalRecord?.result else {
            return "Off: \(ActivityCalibrationProtocols.runsToPersonalise) runs needed."
        }
        switch result.outcome {
        case .needsMoreRuns(let have, let need):
            let more = max(1, need - have)
            return "Off: \(more) more run\(more == 1 ? "" : "s") needed."
        case .adopted(let profile):
            let since = Date(timeIntervalSince1970: TimeInterval(profile.fittedAt)).formatted(date: .abbreviated, time: .omitted)
            guard let v = profile.validation else { return "Active since \(since)." }
            let (label, before, after) = Self.headlineAccuracy(v)
            return "Active since \(since): \(label) \(Self.pct(before)) -> \(Self.pct(after)) on your held-out runs."
        case .notBetter:
            return "Tried, not better; keeping the defaults."
        }
    }

    private var personalDetail: String? {
        guard personalScoped, let result = personalRecord?.result else {
            return "Each run teaches the activity view how you sit, stand and lie down. Do them on different days. Your profile is only used once it beats the defaults on runs it was not fit on."
        }
        switch result.status {
        case .needsMoreRuns:
            return "\(result.runs) usable run\(result.runs == 1 ? "" : "s") so far. Your profile is tested on runs it was not fit on, so it needs at least \(result.runsNeeded)."
        case .adopted, .notBetter:
            guard let v = result.validation else { return nil }
            let classes = ActivityPersonalProfile.modeKeys.compactMap { key -> String? in
                guard let c = v.classes[key] else { return nil }
                return "\(Self.modeName(key)) \(Self.pct(c.baselineRecall)) -> \(Self.pct(c.personalRecall))"
            }
            var line = "Defaults -> yours, over \(v.runs) runs: " + classes.joined(separator: ", ") + "."
            if v.transitions > 0 {
                line += " Position changes caught: \(v.baselineTransitionHits) -> \(v.personalTransitionHits) of \(v.transitions)."
            }
            return line
        }
    }

    /// Sitting/standing accuracy when both were held out (the pair the defaults confuse most), else overall.
    private static func headlineAccuracy(_ v: ActivityPersonalValidation) -> (String, Double, Double) {
        if let sit = v.classes["seated"], let stand = v.classes["upright"] {
            return ("sitting/standing accuracy", (sit.baselineRecall + stand.baselineRecall) / 2,
                    (sit.personalRecall + stand.personalRecall) / 2)
        }
        return ("accuracy", v.baselineBalancedAccuracy, v.personalBalancedAccuracy)
    }

    private static func modeName(_ key: String) -> String {
        switch key {
        case "bedRest": return "lying"
        case "seated": return "sitting"
        case "upright": return "standing"
        case "walk": return "walking"
        case "briskWalk": return "brisk walking"
        default: return key
        }
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    // MARK: - Gate

    /// The live gate verdict. Pure reads over observable state, shared by the runner's injected
    /// closure and by the Start button's disabled state.
    private var gate: ActivityCalibrationSessionRunner.GateStatus {
        Self.gateStatus(model: model, live: live)
    }

    private var gateIsReady: Bool {
        if case .ready = gate { return true }
        return false
    }

    private static func gateStatus(model: AppModel, live: LiveState)
        -> ActivityCalibrationSessionRunner.GateStatus {
        guard live.connected, live.bonded else { return .blocked(.whoopNotConnected) }
        guard model.ble.isWhoop5 else { return .blocked(.rawUnavailable) }
        guard live.worn else { return .blocked(.notOnWrist) }
        if let pct = live.batteryPct,
           pct <= Double(ActivityImuCapture.defaultPauseBatteryPct),
           !(live.charging ?? false) {
            return .blocked(.batteryLow(pct: Int(pct.rounded(.down))))
        }
        // A Raw Data session owns the IMU stream (`reconcileActivityImu` never fights it). The durable
        // intent reflects a session started from ANY screen, not just one this page saw.
        guard !RawDataSessionStore.persistedCaptureIntentIsActive else { return .blocked(.rawSessionInFlight) }
        return .ready
    }

    // MARK: - Haptics

    static let moveBuzzes: UInt8 = 1
    static let doneBuzzes: UInt8 = 3

    /// Strap buzz (acknowledged, so the IMU stream cannot crowd it out) plus the phone's Taptic Engine.
    private static func fireCue(_ cue: ActivityCalibrationSessionRunner.Cue, model: AppModel) {
        #if os(iOS)
        switch cue {
        case .move: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .done: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
        model.buzzCue(loops: cue == .move ? moveBuzzes : doneBuzzes)
    }

    // MARK: - Label persistence

    /// One completed step -> one strong guided label, persisted through the shared store (which fills
    /// `sensorQuality` + `rawRefs` from the phone's own raw-IMU coverage at save time). The label
    /// interval is the runner's guarded `[intervalStartTs, intervalEndTs)`; the step edges and the
    /// move cue ride along in `cueContext` so reaction-time margins stay auditable.
    private static func persist(bout: ActivityCalibrationBout, model: AppModel, sessionID: CalibrationSessionID) {
        let label = ActivityGroundTruthLabel(
            labelKey: ActivityGroundTruthLabel.labelKey(source: .guided, sessionId: sessionID.value,
                                                        stretchKey: nil, startTs: bout.intervalStartTs,
                                                        repetition: 1),
            source: .guided,
            sessionId: sessionID.value,
            protocolVersion: bout.protocolVersion,
            repetition: 1,
            deviceId: model.ble.deviceId,
            startTs: bout.intervalStartTs,
            endTs: bout.intervalEndTs,
            posture: bout.posture,
            transitionKind: bout.transitionKind,
            transitionTs: bout.transitionTs,
            labelConfidence: 1.0,
            cueContext: ActivityGroundTruthCueContext(
                instructionTs: bout.stepStartTs,
                countdownStartTs: bout.cueTs == nil ? nil : bout.stepStartTs,
                cueStartTs: bout.cueTs ?? bout.stepStartTs,
                cueStopTs: bout.stepEndTs,
                intervalStartTs: bout.intervalStartTs,
                intervalEndTs: bout.intervalEndTs))
        _ = ActivityGroundTruthStore.shared.upsert(label)
    }

    // MARK: - Live card

    @ViewBuilder private var liveCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                switch runner.phase {
                case .idle:
                    idleContent
                case .gate(let reason):
                    blockedContent(reason)
                case .ready(let activity):
                    readyContent(activity)
                case .countdown(let activity, let endsAt):
                    countdownContent(activity, endsAt: endsAt)
                case .step(let step):
                    stepContent(step)
                case .finished:
                    endedContent(title: "Session complete")
                case .cancelled:
                    endedContent(title: "Session stopped")
                }
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("About \(Self.minutes(protocolModel.estimatedSeconds())) min")
                .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            ForEach(Array(protocolModel.activities.enumerated()), id: \.element.id) { index, activity in
                Text("\(index + 1). \(activity.title) - \(Self.duration(activity.seconds))")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            rulesText
            gateLine
        }
    }

    private var rulesText: some View {
        Text("Only move when the strap buzzes. One buzz: move now. Three buzzes: that activity is done. Each activity starts when you tap Start, and you can skip either one.")
            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var gateLine: some View {
        switch gate {
        case .ready:
            Text("Ready. Keep the strap on your wrist for the whole session.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusPositive)
        case .blocked(let reason):
            Text("Can't start: \(Self.blockReasonText(reason))")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
        }
    }

    private func blockedContent(_ reason: ActivityCalibrationSessionRunner.BlockedReason) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Session stopped").font(StrandFont.title2).foregroundStyle(StrandPalette.statusWarning)
            Text("\(Self.blockReasonText(reason).prefix(1).capitalized + Self.blockReasonText(reason).dropFirst()). Steps already finished are saved; the IMU capture mode is back to its previous setting.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readyContent(_ index: Int) -> some View {
        let activity = protocolModel.activities[index]
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Activity \(index + 1) of \(protocolModel.activities.count)")
                .font(StrandFont.overline).foregroundStyle(StrandPalette.textSecondary)
            Text(activity.title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(activity.setup)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Takes \(Self.duration(activity.seconds)). Tap Start once you're in position; the steps then run on their own.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countdownContent(_ index: Int, endsAt: Date) -> some View {
        let activity = protocolModel.activities[index]
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            cueOverline("Get settled", color: StrandPalette.textSecondary)
            if let first = activity.tasks.first {
                Text("First: \(first.title.lowercased()). \(first.instructions)")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            bigCount(to: endsAt)
            progressLine(activity: index, task: nil)
        }
    }

    @ViewBuilder private func stepContent(_ step: ActivityCalibrationSessionRunner.Step) -> some View {
        let tasks = protocolModel.activities[step.activity].tasks
        let task = tasks[step.task]
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if let cueAt = step.cueAt, !step.moved {
                cueOverline("Get ready", color: StrandPalette.textSecondary)
                Text("\(task.title) on the buzz")
                    .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text("Stay \(Self.postureWord(previousPosture(tasks, before: step.task))) until it buzzes.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                bigCount(to: cueAt)
            } else if task.isMove {
                cueOverline("Now", color: StrandPalette.accent)
                Text(task.title).font(StrandFont.display(34)).foregroundStyle(StrandPalette.accent)
                Text(task.instructions)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                nextLine(tasks, after: step.task)
            } else {
                cueOverline("Hold", color: StrandPalette.accent)
                Text(task.title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text(task.instructions)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                bigCount(to: step.endsAt, suffix: "s")
                nextLine(tasks, after: step.task)
            }
            progressLine(activity: step.activity, task: step.task)
        }
    }

    private func endedContent(title: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(endedLine)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endedLine: String {
        var line = "\(status.savedCount) step\(status.savedCount == 1 ? "" : "s") saved."
        let skipped = runner.skipped.sorted().compactMap { protocolModel.activities.indices.contains($0) ? protocolModel.activities[$0].title : nil }
        if !skipped.isEmpty {
            line += " Skipped: \(skipped.joined(separator: ", "))."
        }
        line += " The IMU capture mode is back to its previous setting."
        return line
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        switch runner.phase {
        case .idle, .gate, .finished, .cancelled:
            NoopButton("Start calibration", systemImage: "play.fill", kind: .primary, fullWidth: true) {
                // A fresh session id per run, so a stopped-and-restarted run is its own session.
                sessionID.value = UUID().uuidString
                runner.begin(previousMode: ActivityImuCapture.mode())
            }
            .disabled(!gateIsReady)
        case .ready:
            VStack(spacing: NoopMetrics.space3) {
                NoopButton("Start", systemImage: "play.fill", kind: .primary, fullWidth: true) { runner.start() }
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Skip activity", systemImage: "forward.fill", kind: .secondary) { runner.skip() }
                    NoopButton("Stop", systemImage: "stop.fill", kind: .secondary) { runner.finish() }
                }
            }
        case .countdown, .step:
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Skip activity", systemImage: "forward.fill", kind: .secondary) { runner.skip() }
                NoopButton("Stop", systemImage: "stop.fill", kind: .secondary) { runner.finish() }
            }
        }
    }

    @ViewBuilder private var savedSummary: some View {
        if status.savedCount > 0 {
            StrandCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Ground truth").font(StrandFont.overline).foregroundStyle(StrandPalette.textSecondary)
                    Text(savedSummaryLine)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    private var savedSummaryLine: String {
        var line = "\(status.savedCount) label\(status.savedCount == 1 ? "" : "s") saved"
        if let savedAt = status.lastSavedAt {
            line += " - last at \(savedAt.formatted(date: .omitted, time: .shortened))"
        }
        line += ". They upload with your account's ground-truth sync."
        return line
    }

    // MARK: - Helpers

    private func cueOverline(_ text: String, color: Color) -> some View {
        Text(text.uppercased()).font(StrandFont.overline).foregroundStyle(color)
    }

    /// "Next: Stand up on the buzz" while a step runs; the activity's end after its last step.
    private func nextLine(_ tasks: [ActivityCalibrationTask], after index: Int) -> some View {
        let text: String
        if tasks.indices.contains(index + 1) {
            let next = tasks[index + 1]
            text = next.isMove ? "Next: \(next.title.lowercased()) on the buzz." : "Next: \(next.title.lowercased())."
        } else {
            text = "Last step: three buzzes when it ends."
        }
        return Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
    }

    private func previousPosture(_ tasks: [ActivityCalibrationTask], before index: Int) -> String? {
        guard index > 0 else { return PostureClass.seatedLikely.rawValue }
        let previous = tasks[index - 1]
        return previous.isMove ? previous.endPosture : previous.posture
    }

    private static func postureWord(_ raw: String?) -> String {
        switch raw {
        case PostureClass.uprightStationary.rawValue?: return "standing"
        case PostureClass.recumbent.rawValue?: return "lying down"
        default: return "seated"
        }
    }

    /// "Activity i of N - Step j of m".
    private func progressLine(activity: Int, task: Int?) -> some View {
        let activities = protocolModel.activities
        var text = "Activity \(activity + 1) of \(activities.count)"
        if let task, activities.indices.contains(activity) {
            text += " - Step \(task + 1) of \(activities[activity].tasks.count)"
        }
        return Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
    }

    /// Whole seconds left until `deadline`, never below 1 while it is still ahead, so "0" never shows
    /// before the runner acts on the deadline.
    private func bigCount(to deadline: Date, suffix: String = "") -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let remaining = deadline.timeIntervalSince(timeline.date)
            Text("\(max(1, Int(remaining.rounded(.up))))\(suffix)")
                .font(StrandFont.display(44))
                .foregroundStyle(StrandPalette.accent)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private static func minutes(_ seconds: Int) -> Int { max(1, Int((Double(seconds) / 60).rounded())) }

    private static func duration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m == 0 { return "\(s) s" }
        return s == 0 ? "\(m) min" : "\(m) min \(s) s"
    }

    private static func blockReasonText(_ reason: ActivityCalibrationSessionRunner.BlockedReason) -> String {
        switch reason {
        case .whoopNotConnected:
            return "the WHOOP isn't connected and paired"
        case .notOnWrist:
            return "the strap isn't on your wrist"
        case .batteryLow(let pct):
            return "strap battery is \(pct)% (at or below the \(ActivityImuCapture.defaultPauseBatteryPct)% capture pause)"
        case .rawUnavailable:
            return "this strap doesn't provide the 100 Hz raw motion stream"
        case .rawSessionInFlight:
            return "a Raw Data session is recording - finish or stop it first"
        }
    }
}

/// The mutable session identity the onBout closure and the Start button share across the page's
/// re-renders (a `@State`-preserved reference box).
@MainActor private final class CalibrationSessionID {
    var value = UUID().uuidString
}

/// Saved-label feedback, observed by the page through `@StateObject`.
@MainActor private final class CalibrationStatus: ObservableObject {
    @Published var savedCount = 0
    @Published var lastSavedAt: Date?
}

#if DEBUG
/// DEBUG-only deterministic render target for `--demo-screen activitycalibration`: the page in its
/// idle state (the runner is rendered, never started, so no strap side effects). Same convention as
/// `OnboardingScanDemoScreen` / `DeviceCardCatalog`.
struct ActivityCalibrationDemoScreen: View {
    @StateObject private var model = AppModel()
    var body: some View {
        ActivityCalibrationView()
            .environmentObject(model)
            .environmentObject(model.live)
            .frame(width: 1100, height: 780)
    }
}
#endif
