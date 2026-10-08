import SwiftUI
import Foundation
import StrandDesign

/// Silent haptic HIIT interval timer.
///
/// Train hands-free: the strap buzzes every transition so you never have to look
/// at the screen. Strong triple-buzz at the start of each WORK block, a short
/// single buzz into REST, a 3-2-1 tick on the last seconds of every phase, and a
/// long 5-loop buzz when the whole session finishes. With no strap bonded it still
/// works as a big glanceable visual timer (just without haptics).
struct IntervalTimerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    // MARK: Config (persisted only in-view)

    @State private var workSeconds: Int = 30
    @State private var restSeconds: Int = 15
    @State private var rounds: Int = 8

    // MARK: Run state

    private enum Phase { case work, rest, done
        var label: String {
            switch self {
            case .work: return String(localized: "Work")
            case .rest: return String(localized: "Rest")
            case .done: return String(localized: "Done")
            }
        }
    }

    @State private var phase: Phase = .work
    @State private var currentRound: Int = 1
    @State private var remaining: Int = 30          // seconds left in the current phase
    @State private var running: Bool = false
    @State private var elapsed: Int = 0             // total elapsed seconds across the session

    // MARK: iPhone haptics (iOS only)
    //
    // The strap buzz (`buzz`) only fires when a strap is bonded; on iPhone the device in
    // the user's hand has a Taptic Engine, so we mirror every transition cue with native
    // haptics that fire regardless of bond state. A monotonically-bumped Int token drives a
    // single `.sensoryFeedback`, so even a repeated cue (the 3-2-1 tick three seconds running)
    // re-fires because the trigger value always changes.
    #if os(iOS)
    private enum HapticCue { case work, rest, tick, done }
    @State private var lastHaptic: HapticCue = .work
    @State private var hapticTick: Int = 0
    #endif

    // 1Hz tick.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var phaseDuration: Int {
        switch phase {
        case .work: return max(1, workSeconds)
        case .rest: return max(1, restSeconds)
        case .done: return 1
        }
    }

    /// 0...1 progress through the current interval.
    private var intervalProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        let done = Double(phaseDuration - remaining)
        return min(1, max(0, done / Double(phaseDuration)))
    }

    /// Total planned session length in seconds (work*rounds + rest*(rounds-1)).
    private var totalPlanned: Int {
        guard rounds > 0 else { return 0 }
        return workSeconds * rounds + restSeconds * max(0, rounds - 1)
    }

    /// The active phase's reset token: WORK uses the Effort blue, REST the Rest blue-grey, DONE the
    /// positive green. Tints the flat ring arc + the phase chip only (no glow).
    private var phaseColor: Color {
        switch phase {
        case .work: return StrandPalette.effortColor
        case .rest: return StrandPalette.restColor
        case .done: return StrandPalette.statusPositive
        }
    }

    private var isFinished: Bool { phase == .done }

    // MARK: Body

    var body: some View {
        ScreenScaffold(title: "Interval timer") {
            stageCard
            if !live.bonded {
                InlineNotice(String(localized: "Connect your strap to feel the transitions hands-free."), tone: .neutral)
            }
            configCard
        }
        .onReceive(ticker) { _ in tick() }
        .onChangeCompat(of: workSeconds) { _ in if !running { resetToStart() } }
        .onChangeCompat(of: restSeconds) { _ in if !running { resetToStart() } }
        .onChangeCompat(of: rounds) { _ in
            if currentRound > rounds { currentRound = rounds }
            if !running { resetToStart() }
        }
        .onAppear { if remaining == 0 { resetToStart() } }
        // Keep the screen awake while a session runs (no-op on macOS). One onChange covers
        // every running→false transition — manual pause, auto-finish, and reset — and the
        // onDisappear is a safety net so navigating away mid-run never leaves the idle timer
        // disabled app-wide.
        .onChangeCompat(of: running) { ScreenIdle.keepAwake($0) }
        .onDisappear { ScreenIdle.keepAwake(false) }
        #if os(iOS)
        // iPhone haptics: one modifier emits a different feel per cue, re-firing on every
        // token bump. Fires regardless of strap bond so the timer is fully usable unstrapped.
        .sensoryFeedback(trigger: hapticTick) { _, _ in
            switch lastHaptic {
            case .work: return .impact(weight: .heavy)      // strong cue into WORK
            case .rest: return .impact(weight: .light)      // soft cue into REST
            case .tick: return .selection                   // 3-2-1 countdown tick
            case .done: return .success                     // session complete
            }
        }
        #endif
    }

    // MARK: Stage card — the countdown hero on a flat opaque surface

    /// The running timer is the hero: a clean flat phase-progress ring (GlowRing-style — visible
    /// track, solid arc, NO glow/bloom) with the countdown at its centre, on a flat opaque
    /// surfaceRaised card. Design Reset: no scenic backdrop, no tinted frost, no gauge gradient —
    /// the active phase's reset token tints only the arc + chip, the card stays WHOOP-grey.
    private var stageCard: some View {
        NoopCard {
            VStack(spacing: NoopMetrics.space4) {
                // Phase word + round line.
                HStack {
                    phaseChip
                    Spacer()
                    roundChip
                }

                // The flat hero progress ring with the countdown at its centre.
                heroRing
                    .frame(maxWidth: .infinity)

                controls

                // The whole session's progress toward its planned length (a real target).
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack {
                        Text("Session").strandLabel()
                        Spacer()
                        Text("\(timeString(elapsed)) / \(timeString(totalPlanned))")
                            .font(StrandFont.subhead.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    ProgressView(value: sessionProgress)
                        .tint(StrandPalette.effortColor)
                        .accessibilityLabel("Session progress")
                        .accessibilityValue("\(Int((sessionProgress * 100).rounded())) percent")
                }
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    /// Flat phase-progress ring (GlowRing look — visible track + solid reset-token arc, no bloom)
    /// with the countdown number + caption centred. The arc springs to the live fraction; no
    /// separate bloom driver.
    private var heroRing: some View {
        let diameter: CGFloat = 240
        let lineWidth: CGFloat = 18
        let fraction = isFinished ? 1 : intervalProgress
        return ZStack {
            // Visible full-circle track, so the arc reads as a fraction of a circle (WHOOP-style).
            Circle()
                .stroke(StrandPalette.surfaceInset, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            // Flat, crisp solid arc — no glow. It eases between seconds (off under Reduce Motion and the
            // quiet-motion gate).
            Circle()
                .trim(from: 0, to: max(0.0001, CGFloat(min(max(fraction, 0), 1))))
                .rotation(.degrees(-90))
                .stroke(phaseColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // A zero-length round-capped arc would still draw a dot at 12 o'clock.
                .opacity(fraction > 0.001 ? 1 : 0)
                .animation(motion.poseStill(reduceMotion) ? nil : .easeInOut(duration: 0.25), value: fraction)
            // Centred countdown number + caption.
            VStack(spacing: 4) {
                Text(isFinished ? "✓" : "\(remaining)")
                    .font(GlowRing.centerFont(diameter: diameter))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(isFinished ? "Session done" : "Seconds")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.horizontal, lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinished ? "Session done" : "\(remaining) seconds remaining in \(phase.label)")
    }

    /// The phase in a word (Work / Rest / Done), with whether the session is running.
    private var phaseChip: some View {
        StatePill(LocalizedStringKey(running || isFinished ? phase.label
                                     : (elapsed == 0 ? String(localized: "Ready") : String(localized: "Paused"))),
                  tone: isFinished ? .positive : (phase == .work ? .accent : .neutral))
    }

    /// "Round n of N".
    private var roundChip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Round").strandLabel()
            Text("\(min(currentRound, rounds))")
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("/ \(rounds)")
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton(running ? "Pause" : (isFinished ? "Restart" : "Start"),
                       systemImage: running ? "pause.fill" : "play.fill",
                       kind: .primary, fullWidth: true) {
                if isFinished { resetToStart() }
                toggleRunning()
            }

            NoopButton("Reset", systemImage: "arrow.counterclockwise",
                       kind: .secondary, fullWidth: true) {
                stopAndReset()
            }
            .disabled(!running && remaining == phaseDuration && currentRound == 1 && phase == .work && elapsed == 0)
        }
    }

    private var sessionProgress: Double {
        guard totalPlanned > 0 else { return 0 }
        return min(1, max(0, Double(elapsed) / Double(totalPlanned)))
    }

    // MARK: Config card

    private var configCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                configStepper(title: String(localized: "Work"), unit: String(localized: "sec"), value: $workSeconds,
                              range: 5...600, step: 5, tint: StrandPalette.effortColor)
                Divider().overlay(StrandPalette.hairline)
                configStepper(title: String(localized: "Rest"), unit: String(localized: "sec"), value: $restSeconds,
                              range: 5...600, step: 5, tint: StrandPalette.restColor)
                Divider().overlay(StrandPalette.hairline)
                configStepper(title: String(localized: "Rounds"), unit: nil, value: $rounds,
                              range: 1...30, step: 1, tint: StrandPalette.textPrimary)
            }
            .disabled(running)
            .opacity(running ? StrandPalette.disabledOpacity : 1)
        }
    }

    private func configStepper(title: String, unit: String?, value: Binding<Int>,
                               range: ClosedRange<Int>, step: Int, tint: Color) -> some View {
        HStack {
            Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value.wrappedValue)")
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 44, alignment: .trailing)
                if let unit {
                    Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel("\(title) \(unit ?? "")")
        }
    }

    // MARK: Timer logic

    private func tick() {
        guard running, !isFinished else { return }

        // Optional 3-2-1 countdown tick on the last seconds of the current phase.
        if remaining <= 3 && remaining >= 1 {
            buzz(loops: 1)
            #if os(iOS)
            haptic(.tick)
            #endif
        }

        if remaining > 1 {
            remaining -= 1
            elapsed += 1
            return
        }

        // remaining hits 0 — advance to the next phase/round.
        elapsed += 1
        advancePhase()
    }

    private func advancePhase() {
        switch phase {
        case .work:
            if currentRound >= rounds {
                // Last work block finished → session complete.
                finishSession()
            } else {
                // Into rest.
                phase = .rest
                remaining = max(1, restSeconds)
                buzz(loops: 1)              // short cue into rest
                #if os(iOS)
                haptic(.rest)
                #endif
            }
        case .rest:
            // Rest done → next round's work.
            currentRound += 1
            phase = .work
            remaining = max(1, workSeconds)
            buzz(loops: 3)                  // strong cue into work
            #if os(iOS)
            haptic(.work)
            #endif
        case .done:
            break
        }
    }

    private func finishSession() {
        phase = .done
        remaining = 0
        running = false
        buzz(loops: 5)                      // long completion cue
        #if os(iOS)
        haptic(.done)
        #endif
    }

    private func toggleRunning() {
        if isFinished { return }
        if running {
            running = false
        } else {
            // Starting fresh from a clean reset → fire the opening WORK cue.
            let startingFresh = (phase == .work && currentRound == 1
                                 && remaining == max(1, workSeconds) && elapsed == 0)
            running = true
            if startingFresh {
                buzz(loops: 3)
                #if os(iOS)
                haptic(.work)
                #endif
            }
        }
    }

    private func stopAndReset() {
        running = false
        resetToStart()
    }

    /// Reset run state back to round 1 / start of work, using current config.
    private func resetToStart() {
        phase = .work
        currentRound = 1
        remaining = max(1, workSeconds)
        elapsed = 0
    }

    /// Fire a strap buzz (no-op when not bonded — `buzz` already guards, but we
    /// also skip the call entirely so this stays a pure visual tool when unbonded).
    private func buzz(loops: UInt8) {
        guard live.bonded else { return }
        model.buzz(loops: loops, gate: HapticPrefs.intervals)
    }

    #if os(iOS)
    /// Fire an iPhone haptic cue. Additive to `buzz` and unguarded by bond state, so the
    /// timer gives tactile feedback even with no strap. Bumping the token re-triggers
    /// `.sensoryFeedback` even when the same cue repeats.
    private func haptic(_ cue: HapticCue) {
        lastHaptic = cue
        hapticTick &+= 1
    }
    #endif

    // MARK: Formatting

    private func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

#if DEBUG
#Preview("Interval Timer") {
    IntervalTimerView()
        .environmentObject(AppModel())
        .environmentObject(LiveState())
        .frame(width: 720, height: 900)
        .preferredColorScheme(.dark)
}
#endif
