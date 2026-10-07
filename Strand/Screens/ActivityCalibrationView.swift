import SwiftUI
import StrandDesign
import StrandAnalytics

// ActivityCalibrationView.swift - Test Centre's guided activity ground-truth capture.
//
// Drives ActivityCalibrationSessionRunner (the pure, closure-injected state machine in
// Strand/Collect/ActivityCalibrationSession.swift) against the live BLE/live state, and turns each
// completed bout into an ActivityGroundTruthLabel persisted through ActivityGroundTruthStore.shared.
// Every transition cue buzzes the strap (model.buzz) and, on iOS, the phone's Taptic Engine; the
// 3 s pre-task countdown and the in-bout count render through TimelineView.
//
// Additive only: this file touches nothing that exists. The runner owns the durable restore marker
// and the IMU capture-mode override; the view only wires the gate, the haptics and the clock.

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
    /// Rotated on each `begin`, so a cancelled-and-restarted run is its own evaluation session.
    @State private var sessionID = CalibrationSessionID()
    /// Feedback counters fed by the `onBout` closure (a reference box the view observes).
    @StateObject private var status = CalibrationStatus()
    /// The last personal-profile fit for this account and strap, and whether one is running now.
    @State private var personalRecord: ActivityPersonalProfileStore.Record?
    @State private var personalScoped = true
    @State private var refitting = false

    @Environment(\.scenePhase) private var scenePhase

    /// 1 Hz state-machine tick + mid-session gate re-check. Runs while the page is in the hierarchy;
    /// both calls are no-ops when the session is idle or not running.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: AppModel, live: LiveState) {
        self.model = model
        self.live = live
        let runner = ActivityCalibrationSessionRunner(
            protocol: ActivityCalibrationProtocols.current,
            deviceId: nil,   // the label builder reads model.ble.deviceId at save time
            gate: { ActivityCalibrationPage.gateStatus(model: model, live: live) },
            applyMode: { mode in model.ble.setActivityImuCaptureMode(mode) },
            haptic: { ActivityCalibrationPage.fireHaptic(model: model) },
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

    private var isRunning: Bool {
        switch runner.phase {
        case .countdown, .active, .rest: return true
        default: return false
        }
    }

    private func holdScreenAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    var body: some View {
        ScreenScaffold(
            title: "Activity calibration",
            subtitle: "Guided labeled movement sessions for activity research."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                overviewCard
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
            holdScreenAwake(isRunning)
        }
        .onDisappear { holdScreenAwake(false) }
        .onChangeCompat(of: scenePhase) { phase in
            // A backgrounded scene cannot keep timing honest: stop the session exactly like a cancel
            // (previous IMU mode restored, durable marker cleared) so nothing is left forced. A banner or
            // Control Center only makes the scene inactive, which does not stop the clock.
            if phase == .background { runner.cancel() }
        }
        .onChangeCompat(of: runner.phase) { phase in
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
            return "Off: \(ActivityPersonalProfileFitter.minRuns) runs needed."
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
            return "Each run teaches the activity view how you sit, stand, lie and walk. It is only used once it beats the defaults on runs it was not fit on."
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
    /// closure (which re-evaluates it on begin, at rest boundaries and on our 1 Hz refresh) and by
    /// the Start button's disabled state.
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

    /// Phone Taptic Engine on iOS (macOS has no equivalent) plus the strap's one-shot buzz, mirroring
    /// the Live "Buzz strap" cue. The runner calls this at countdown->cue, transition-cue and stop.
    private static func fireHaptic(model: AppModel) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        model.buzz(loops: 2)
    }

    // MARK: - Label persistence

    /// One completed bout -> one strong guided label, persisted through the shared store (which fills
    /// `sensorQuality` + `rawRefs` from the phone's own raw-IMU coverage at save time). The label
    /// interval is the runner's cue-guarded `[intervalStartTs, intervalEndTs)`; the cue timestamps
    /// ride along in `cueContext` so reaction-time margins stay auditable.
    private static func persist(bout: ActivityCalibrationBout, model: AppModel, sessionID: CalibrationSessionID) {
        let label = ActivityGroundTruthLabel(
            labelKey: ActivityGroundTruthLabel.labelKey(source: .guided, sessionId: sessionID.value,
                                                        stretchKey: nil, startTs: bout.intervalStartTs,
                                                        repetition: bout.repetition),
            source: .guided,
            sessionId: sessionID.value,
            protocolVersion: bout.protocolVersion,
            repetition: bout.repetition,
            deviceId: model.ble.deviceId,
            startTs: bout.intervalStartTs,
            endTs: bout.intervalEndTs,
            posture: bout.posture,
            locomotion: bout.locomotion,
            armBehavior: bout.armBehavior,
            transitionKind: bout.transitionKind,
            transitionTs: bout.transitionTs,
            semanticTag: bout.semanticTag,
            labelConfidence: 1.0,
            cueContext: ActivityGroundTruthCueContext(
                instructionTs: bout.instructionTs,
                countdownStartTs: bout.countdownStartTs,
                cueStartTs: bout.cueStartTs,
                cueStopTs: bout.cueStopTs,
                intervalStartTs: bout.intervalStartTs,
                intervalEndTs: bout.intervalEndTs))
        _ = ActivityGroundTruthStore.shared.upsert(label)
    }

    // MARK: - Cards

    private var overviewCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Session").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("\(protocolSummary)")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Text("Keep the strap on your wrist and follow the on-screen cues. Each step labels the raw 100 Hz motion the strap records during it.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var liveCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                switch runner.phase {
                case .idle:
                    idleContent
                case .gate(let reason):
                    blockedContent(reason)
                case .countdown(let taskIndex, let endsAt):
                    countdownContent(taskIndex: taskIndex, endsAt: endsAt)
                case .active(let taskIndex, let rep, let cueStartTs):
                    activeContent(taskIndex: taskIndex, rep: rep, cueStartTs: cueStartTs)
                case .rest(let taskIndex, let rep, let endsAt):
                    restContent(taskIndex: taskIndex, rep: rep, endsAt: endsAt)
                case .finished:
                    finishedContent
                case .cancelled:
                    cancelledContent
                }
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Guided calibration").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("A short stretch of an ordinary day: sitting and desk work, standing up, a walk, lying down and getting up. Each step flows into the next; read the next step during the 3 s countdown and move when the strap buzzes. You'll need a chair, a few metres to walk and a bed or sofa. A few runs on different days help more than one long one.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            gateLine
        }
    }

    @ViewBuilder private var gateLine: some View {
        switch gate {
        case .ready:
            Text("Ready. Connect the strap and keep it on your wrist for the whole session.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusPositive)
        case .blocked(let reason):
            Text("Can't start: \(Self.blockReasonText(reason))")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
        }
    }

    private func blockedContent(_ reason: ActivityCalibrationSessionRunner.BlockedReason) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Session blocked").font(StrandFont.title2).foregroundStyle(StrandPalette.statusWarning)
            Text("\(Self.blockReasonText(reason)) The session was stopped and the IMU capture mode restored to its previous setting.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countdownContent(taskIndex: Int, endsAt: Date) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if let task = task(at: taskIndex) {
                taskHeader(task)
                Text(task.instructions)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Get ready")
                    .font(StrandFont.overline).foregroundStyle(StrandPalette.textSecondary)
                countdownNumber(until: endsAt)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            progressLine(taskIndex: taskIndex, rep: nil)
        }
    }

    private func activeContent(taskIndex: Int, rep: Int, cueStartTs: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if let task = task(at: taskIndex) {
                taskHeader(task)
                Text(task.instructions)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                    let waiting = ActivityCalibrationSessionRunner.hasHeldPreState(task)
                        && Int(timeline.date.timeIntervalSince1970) < cueStartTs + (task.preStateSeconds ?? 0)
                    Text(task.transitionKind == nil ? "Keep going" : (waiting ? "Hold, wait for the buzz" : "Move now"))
                        .font(StrandFont.overline).foregroundStyle(StrandPalette.accent)
                }
                activeRemaining(task: task, cueStartTs: cueStartTs)
                    .frame(maxWidth: .infinity, alignment: .center)
                if task.transitionKind != nil, let pre = task.preStateSeconds, pre > 0 {
                    // "I've done it" lets a transition task fire early (before the auto cue at
                    // `cueStartTs + pre`). Hidden once the auto-cue window passes.
                    TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                        if Int(timeline.date.timeIntervalSince1970) < cueStartTs + pre {
                            NoopButton("I've done it", systemImage: "hand.tap", kind: .secondary,
                                       fullWidth: true) {
                                runner.markTransitionNow()
                            }
                        }
                    }
                }
            }
            progressLine(taskIndex: taskIndex, rep: rep)
        }
    }

    private func restContent(taskIndex: Int, rep: Int, endsAt: Date) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Rest").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Stay as you are. The next step starts automatically.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            countdownNumber(until: endsAt)
                .frame(maxWidth: .infinity, alignment: .center)
            progressLine(taskIndex: taskIndex, rep: nil)
        }
    }

    private var finishedContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Session complete").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("\(status.savedCount) ground-truth label\(status.savedCount == 1 ? "" : "s") saved. The IMU capture mode has been restored to its previous setting.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cancelledContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Session cancelled").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("No session is running and the IMU capture mode has been restored. \(status.savedCount) label\(status.savedCount == 1 ? "" : "s") were saved before you stopped.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        switch runner.phase {
        case .idle, .gate, .finished, .cancelled:
            NoopButton("Start calibration session", systemImage: "play.fill", kind: .primary,
                       fullWidth: true) {
                // A fresh session id per run, so a cancelled-and-restarted run is its own session.
                sessionID.value = UUID().uuidString
                runner.begin(previousMode: ActivityImuCapture.mode())
            }
            .disabled(!gateIsReady)
        case .countdown, .active, .rest:
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Cancel", systemImage: "xmark", kind: .secondary) { runner.cancel() }
                NoopButton("Finish", systemImage: "checkmark", kind: .primary) { runner.finish() }
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

    private func task(at index: Int) -> ActivityCalibrationTask? {
        let tasks = ActivityCalibrationProtocols.current.tasks
        return tasks.indices.contains(index) ? tasks[index] : nil
    }

    private var protocolSummary: String {
        let model = ActivityCalibrationProtocols.current
        let totalSeconds = model.estimatedSeconds(countdownSeconds: ActivityCalibrationSessionRunner.countdownSeconds)
        let minutes = max(1, Int((Double(totalSeconds) / 60).rounded(.up)))
        return "\(model.tasks.count) steps - about \(minutes) min - \(model.version)"
    }

    private func taskHeader(_ task: ActivityCalibrationTask) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(task.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            if let category = ActivityCalibrationTaskCategory(rawValue: task.category) {
                Text(category.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// "Task i of N [ - Rep j of m]" for the running task; the countdown phase has no rep yet.
    private func progressLine(taskIndex: Int, rep: Int?) -> some View {
        let tasks = ActivityCalibrationProtocols.current.tasks
        var line: String?
        if tasks.indices.contains(taskIndex) {
            let task = tasks[taskIndex]
            var text = "Step \(taskIndex + 1) of \(tasks.count)"
            if let rep, task.repetitions > 1 {
                text += " - Rep \(rep + 1) of \(task.repetitions)"
            }
            line = text
        }
        return Text(line ?? "")
            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
    }

    /// Live countdown numeral, ticking through TimelineView so it re-renders between runner ticks.
    private func countdownNumber(until endsAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let remaining = max(0, endsAt.timeIntervalSince(timeline.date))
            Text("\(Int(remaining.rounded(.up)))")
                .font(StrandFont.display(40))
                .foregroundStyle(StrandPalette.accent)
        }
    }

    private func activeRemaining(task: ActivityCalibrationTask, cueStartTs: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let remaining = max(0, TimeInterval(cueStartTs) + TimeInterval(task.durationSeconds)
                                - timeline.date.timeIntervalSince1970)
            Text("\(Int(remaining.rounded(.up)))s")
                .font(StrandFont.display(40))
                .foregroundStyle(StrandPalette.accent)
        }
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
