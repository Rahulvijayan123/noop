import Foundation

// StressOnsetDetector.swift — the L3 closed-loop JITAI ("just-in-time adaptive intervention") detector.
// Generalises the math currently inline in `AppModel.evaluateStress()` into an EDGE-triggered,
// motion-gated, REPLAY-SAFE detector that decides — at the moment it matters — whether to offer a 60-s
// guided breathing cue. PURE + DB-free, carrying its OWN de-dup state exactly like
// `SedentaryDetector.evaluate`: the caller persists `nextState` and feeds it back, so a replayed window
// can't re-fire. No I/O / BLE here.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
//
// WHAT IT GENERALISES (from AppModel.evaluateStress): a rolling clean-R-R buffer → a SLOW RMSSD baseline
// (the shipped 0.98/0.02 EMA) + a resting-HR band gate (55–100 bpm) + a `rmssd < baseline × 0.6` drop +
// a once-per-15-min limiter + a single confirming buzz. What this engine ADDS, per spec:
//   1. A FAST short-window RMSSD (the latest beats) vs the slow baseline — "fast dropped below baseline".
//   2. EDGE trigger: fire ONCE on the fresh crossing (was-above → now-below), not every tick — and
//      only after that crossing has SUSTAINED for `sustainSeconds`, so a momentary RMSSD wobble
//      cannot nudge (a real stress response holds for minutes; see the constant's note).
//   3. The EXERCISE GATE (the credibility line): suppress when HR is out of the resting band AND/OR recent
//      motion says "metabolic, not stress" (gravity activity above a threshold, the same `recentGravity`
//      source `SedentaryDetector` reads). A brisk walk's HRV dip must NOT fire a "you're stressed" cue.
//   4. Rate-limit + quiet hours + master toggle, and never while a manual Breathe/L1/L2 session runs.
//
// HONEST / NON-CLINICAL: "stress" is an autonomic PROXY (HRV-down vs the user's OWN baseline), never a
// diagnosis. The card may say "while you were still" only when `Decision.stillnessVerified` (stationary
// context was supplied); otherwise it must not claim stillness. Never "you are stressed".
// On fire: a single confirming buzz + a passive in-app card; NEVER a push notification unless the user
// opted into notifications (matches DaytimeStress's "passive suggestion, never a notification" stance).
//
// All `ts`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.

public enum StressOnsetDetector {

    // MARK: - Tunables (evaluateStress parity + the new fast/gate pieces)

    /// Slow-baseline EMA weight on the prior value (the shipped 0.98). New RMSSD gets `1 − this`.
    public static let baselineEmaAlpha: Double = 0.98
    /// Fast RMSSD must drop below `baseline × this` to count as a dip (the shipped 0.6 threshold).
    public static let dropRatio: Double = 0.6
    /// Resting HR band — outside it the dip is treated as metabolic (workout), not stress (the shipped
    /// 55–100 bpm gate).
    public static let restingHRLow: Double = 55.0
    public static let restingHRHigh: Double = 100.0
    /// Beats in the FAST short window (the latest clean beats) used for the momentary RMSSD.
    public static let fastWindowBeats: Int = 60
    /// Minimum clean beats before either RMSSD is trusted (mirrors `HRVAnalyzer.minBeats`).
    public static let minBeats: Int = HRVAnalyzer.minBeats
    /// Rate limit — at most one fire per this many seconds (the shipped 900 s = 15 min).
    public static let minSecondsBetweenFires: Int = 900
    /// SUSTAIN: after a fresh crossing the dip must STILL be below the threshold this many seconds
    /// later before it earns a nudge. A genuine autonomic stress response holds for minutes; a
    /// momentary dip in a `fastWindowBeats`-wide RMSSD window is far more often a beat-detection
    /// wobble or a posture change than an arousal. Firing on the bare crossing therefore nudges on
    /// noise: replayed over 40 days of real worn WHOOP data the edge alone fired ~8.4×/day, of which
    /// only ~13 % were still below threshold 60 s later — the rest had already recovered. Requiring
    /// the dip to hold cuts that to ~1×/day WITHOUT relaxing what counts as a dip, which lowering
    /// `dropRatio` alone cannot do (it only makes an equally momentary trigger rarer). 0 disables the
    /// requirement and restores the pre-sustain edge-only behaviour.
    public static let sustainSeconds: Int = 60
    /// Recent smoothed wrist-motion (g) at/above this means "moving" → exercise gate suppresses the fire
    /// (reuses the `SedentaryDetector` move threshold so the two gates agree on what "moving" is).
    public static let motionGateG: Double = SedentaryDetector.defaultMoveThresholdG
    /// After a known postural transition (e.g. sit-to-stand) RMSSD drops orthostatically for a minute or
    /// two. A dip ARMED or confirmed within this many seconds of one is a posture change, not stress, and
    /// the slow baseline does not absorb those ticks either (D4-10 / D6-04).
    public static let transitionSuppressSeconds: Int = 120
    /// After a workout / locomotion bout ends, HRV stays suppressed while the body recovers. Ticks within
    /// this many seconds of the bout's end neither fire nor move the slow baseline.
    public static let postExertionSeconds: Int = 1_800

    // MARK: - Context (D4-10 / D6-04)

    /// What the wrist / decoder knows about the user's activity near now.
    public enum ActivityEvidence: String, Equatable, Sendable {
        /// Nothing supplied (no stored context or step/gravity sample near now). Stillness is UNVERIFIED:
        /// the HR band carries the gate as before, and the decision says so.
        case none
        /// Stationary evidence near now (a stationary-class context run, or motion below the gate).
        case still
        /// Locomotion / activity near now.
        case moving
        /// The decoder ran but could not say (unknown / off-wrist): suppress, never assume still.
        case unknown
    }

    /// The best available context for this tick. Every field defaults to "not known", so a caller that
    /// supplies nothing keeps the pre-context behaviour except that stillness is reported unverified.
    public struct LiveContext: Equatable, Sendable {
        public var activity: ActivityEvidence
        /// True when the user is in a detected sleep / in-bed block (a sleeping RMSSD is not a rest one).
        public var asleep: Bool
        /// Unix seconds of the latest KNOWN postural transition, or nil.
        public var lastTransitionAt: Int?
        /// Unix seconds the latest workout / locomotion bout ENDED, or nil.
        public var lastExertionEndAt: Int?

        public init(activity: ActivityEvidence = .none, asleep: Bool = false,
                    lastTransitionAt: Int? = nil, lastExertionEndAt: Int? = nil) {
            self.activity = activity
            self.asleep = asleep
            self.lastTransitionAt = lastTransitionAt
            self.lastExertionEndAt = lastExertionEndAt
        }

        public static let none = LiveContext()
    }

    // MARK: - Config

    /// The L3 master/sub toggles + quiet-hours window, passed in as plain values so the engine stays pure.
    /// All default OFF / safe — manual-first ethos (the feature is opt-in per layer).
    public struct Config: Equatable, Sendable {
        /// Master "stress check-ins (haptic)" toggle (default OFF). Inert when off.
        public var enabled: Bool
        /// Auto-nudge sub-toggle (default OFF) — when off the detector still reports state but never fires.
        public var autoNudge: Bool
        /// Suppress fires during quiet hours.
        public var quietHoursEnabled: Bool
        /// Quiet-hours window, local minute-of-day [0,1440) (defaults 22:00 → 07:00).
        public var quietStartMinutes: Int
        public var quietEndMinutes: Int
        /// Buzz strength (loops) for the confirming buzz — one light pulse, like evaluateStress.
        public var buzzLoops: Int

        public init(enabled: Bool = false,
                    autoNudge: Bool = false,
                    quietHoursEnabled: Bool = false,
                    quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                    quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                    buzzLoops: Int = 1) {
            self.enabled = enabled
            self.autoNudge = autoNudge
            self.quietHoursEnabled = quietHoursEnabled
            self.quietStartMinutes = quietStartMinutes
            self.quietEndMinutes = quietEndMinutes
            self.buzzLoops = buzzLoops
        }
    }

    // MARK: - State (de-dup / EMA carry — persisted verbatim, replay-safe)

    /// The persisted state the detector carries between evaluations (restart-safe). The caller stores this
    /// verbatim and feeds the prior value back in, exactly like `SedentaryState`. A fresh user starts from
    /// `.initial`. Carries the slow EMA baseline (so it survives relaunch), the edge state (was the fast
    /// RMSSD below the threshold on the previous tick?), and the rate-limit clock.
    public struct State: Equatable, Sendable {
        /// Slow RMSSD baseline (EMA), ms. 0 = uninitialised (seeds from the first trusted fast RMSSD).
        public var baselineRMSSD: Double
        /// Whether the fast RMSSD was BELOW the drop threshold on the previous evaluation — drives the
        /// EDGE (we fire only on a fresh above→below crossing, not every tick it stays below).
        public var wasBelow: Bool
        /// Unix-seconds of the last fire (0 = never) — the rate limiter.
        public var lastFireAt: Int
        /// Unix-seconds of the ARMED crossing awaiting confirmation (0 = nothing armed) — the
        /// `sustainSeconds` clock. Set when a fresh edge crosses below, cleared when the dip
        /// recovers before it holds, and consumed once the sustain is satisfied. Persisted with the
        /// rest of the state so a relaunch mid-dip cannot double-arm.
        public var pendingEdgeAt: Int

        public init(baselineRMSSD: Double = 0, wasBelow: Bool = false, lastFireAt: Int = 0,
                    pendingEdgeAt: Int = 0) {
            self.baselineRMSSD = baselineRMSSD
            self.wasBelow = wasBelow
            self.lastFireAt = lastFireAt
            self.pendingEdgeAt = pendingEdgeAt
        }

        /// Cold-start state (no baseline, not below, never fired).
        public static let initial = State()
    }

    // MARK: - Decision

    /// Why the detector did / didn't nudge — drives logs and the honest card copy.
    public enum Reason: String, Equatable, Sendable {
        /// A fresh non-metabolic HRV dip — offer a minute to breathe.
        case onset
        /// Disabled / auto-nudge off.
        case disabled
        /// Too few clean beats to judge honestly.
        case insufficientData
        /// Fast RMSSD is at/above the threshold — no dip.
        case noDip
        /// The dip isn't a fresh edge (already below last tick, with nothing armed).
        case notAnEdge
        /// A fresh crossing is ARMED but hasn't held for `sustainSeconds` yet — the dip is real so
        /// far, just not yet proven to be more than a momentary wobble.
        case awaitingSustain
        /// Suppressed by the exercise gate (HR out of band and/or recent motion = metabolic, not stress).
        case exerciseGated
        /// Suppressed by context: locomotion / unknown activity near now, asleep, or inside the
        /// post-exertion window (D6-04). Not "stress".
        case contextGated
        /// Suppressed because the dip followed a known postural transition (orthostatic, D4-10).
        case transitionGated
        /// Inside the rate-limit window or quiet hours, or a manual session is running.
        case suppressed
    }

    /// The decision returned each evaluation: whether to nudge, why, and the next state to persist. Mirrors
    /// `SedentaryDecision`: the caller acts on `shouldNudge` and stores `nextState` (always advanced) so a
    /// replayed window can't re-fire.
    public struct Decision: Equatable, Sendable {
        /// True if the app should offer the breathing cue now (single confirming buzz + passive card).
        public let shouldNudge: Bool
        /// Why (whether or not it nudged).
        public let reason: Reason
        /// Buzz loops to play when `shouldNudge` (the confirming buzz).
        public let buzzLoops: Int
        /// The fast short-window RMSSD this tick (ms), or nil when insufficient — for logs / the card.
        public let fastRMSSD: Double?
        /// The slow baseline RMSSD this tick (ms), or nil when uninitialised.
        public let baselineRMSSD: Double?
        /// The state to persist for the next evaluation (always carries the advanced EMA / edge / clock).
        public let nextState: State
        /// True only when stationary context was actually supplied for this tick. A nudge with this false
        /// must not claim the user was "still" (D6-04: that was never verified).
        public let stillnessVerified: Bool
        /// True when this tick's fast RMSSD moved the slow baseline (it passed every rest gate). The EMA is
        /// frozen otherwise, so exercise, sleep, post-workout or a posture change cannot drag it (D4-10).
        public let baselineUpdated: Bool

        public init(shouldNudge: Bool, reason: Reason, buzzLoops: Int,
                    fastRMSSD: Double?, baselineRMSSD: Double?, nextState: State,
                    stillnessVerified: Bool = false, baselineUpdated: Bool = false) {
            self.shouldNudge = shouldNudge; self.reason = reason; self.buzzLoops = buzzLoops
            self.fastRMSSD = fastRMSSD; self.baselineRMSSD = baselineRMSSD; self.nextState = nextState
            self.stillnessVerified = stillnessVerified; self.baselineUpdated = baselineUpdated
        }
    }

    // MARK: - The detector

    /// Evaluate the live window and decide whether to fire a JITAI nudge.
    ///
    /// - `rrBuffer`: the rolling clean-able R-R buffer (rrMs, newest LAST). The fast RMSSD is taken over
    ///   the latest `fastWindowBeats` clean beats; the slow baseline EMA absorbs each trusted fast value.
    /// - `currentHR`: latest smoothed live HR (bpm), or nil if unknown (then the HR half of the gate can't
    ///   pass and we treat HR as out-of-band — conservative).
    /// - `recentMotionG`: recent smoothed wrist-motion (g) from `collector.recentGravity`, or nil if no
    ///   recent gravity (then the motion half of the gate is inconclusive — see below).
    /// - `sessionActive`: true if a manual Breathe/L1/L2 session is already running (never nudge over it).
    /// - `state`: the prior persisted state; `nowSec` / `tzOffsetSec` passed IN (never read a clock).
    ///
    /// The EXERCISE GATE suppresses when EITHER signal says metabolic: HR outside [55,100], OR recent
    /// motion at/above `motionGateG`. A missing HR is treated as out-of-band (can't confirm resting);
    /// missing motion alone does NOT gate (HR-band can carry it — gravity is offloaded and lags, spec Q3),
    /// so the resting-HR band is the real-time gate and motion is a secondary confirm when present.
    ///
    /// `context` (D4-10 / D6-04): locomotion or unknown activity near now, being asleep, or the
    /// post-exertion window suppress a fire (`.contextGated`), and a dip armed or confirmed within
    /// `transitionSuppressSeconds` of a known postural transition is `.transitionGated`. The slow baseline
    /// EMA only absorbs a tick that passes EVERY rest gate (HR band, not moving, not asleep, not
    /// post-exertion, not just after a transition, activity not moving/unknown); otherwise it is frozen.
    public static func evaluate(rrBuffer: [Int],
                                currentHR: Double?,
                                recentMotionG: Double?,
                                sessionActive: Bool,
                                state: State,
                                config: Config,
                                nowSec: Int,
                                tzOffsetSec: Int,
                                context: LiveContext = .none) -> Decision {

        // 1) Master gates: off / auto-nudge off → never nudge, state untouched.
        if !config.enabled || !config.autoNudge {
            return Decision(shouldNudge: false, reason: .disabled, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 2) Fast RMSSD over the latest clean beats. Clean first (range + Malik), then take the tail.
        let cleanAll = HRVAnalyzer.cleanRR(rrBuffer.map { Double($0) })
        let fastWindow = cleanAll.count > fastWindowBeats
            ? Array(cleanAll.suffix(fastWindowBeats))
            : cleanAll
        guard fastWindow.count >= minBeats, let fast = HRVAnalyzer.rmssdRaw(fastWindow), fast > 0 else {
            // Not enough signal — report, don't guess. Edge state is preserved (no crossing observed).
            return Decision(shouldNudge: false, reason: .insufficientData, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 3) The rest gates, evaluated BEFORE the EMA so a non-rest tick cannot move the slow baseline.
        //    HR out of the resting band (or unknown) or recent motion at/above the gate -> metabolic.
        let hrInBand: Bool = {
            guard let hr = currentHR else { return false }   // unknown HR can't confirm resting -> gate
            return hr >= restingHRLow && hr <= restingHRHigh
        }()
        let moving: Bool = {
            guard let m = recentMotionG else { return false } // no recent gravity -> motion inconclusive
            return m >= motionGateG
        }()
        func afterTransition(_ t: Int) -> Bool {
            guard let at = context.lastTransitionAt else { return false }
            return t >= at && t - at < transitionSuppressSeconds
        }
        let postExertion: Bool = {
            guard let end = context.lastExertionEndAt else { return false }
            return nowSec >= end && nowSec - end < postExertionSeconds
        }()
        let contextBlocks = context.activity == .moving || context.activity == .unknown
            || context.asleep || postExertion
        let restTick = hrInBand && !moving && !contextBlocks && !afterTransition(nowSec)
        let stillVerified = context.activity == .still

        // Advance the slow baseline EMA (seed on the first trusted REST value) only on a rest tick.
        var next = state
        if restTick {
            next.baselineRMSSD = state.baselineRMSSD == 0
                ? fast
                : state.baselineRMSSD * baselineEmaAlpha + fast * (1.0 - baselineEmaAlpha)
        }
        guard next.baselineRMSSD > 0 else {
            // No rest tick has seeded the baseline yet: nothing honest to compare against.
            return Decision(shouldNudge: false, reason: hrInBand && !moving ? .contextGated : .exerciseGated,
                            buzzLoops: config.buzzLoops, fastRMSSD: fast, baselineRMSSD: nil,
                            nextState: next, stillnessVerified: stillVerified, baselineUpdated: false)
        }
        let baseline = next.baselineRMSSD

        // 4) Is the fast RMSSD below the drop threshold? (the dip test)
        let threshold = baseline * dropRatio
        let isBelow = fast < threshold
        // The edge: a FRESH crossing (above on the previous tick → below now). Always record the new
        // below-state so the NEXT tick can edge-detect, regardless of whether we fire.
        let isEdge = isBelow && !state.wasBelow
        next.wasBelow = isBelow

        // SUSTAIN: the crossing only ARMS the check. A dip that recovers before it has held for
        // `sustainSeconds` is discarded — it was a wobble, not an arousal — and one that holds is
        // CONSUMED at confirmation time, so a single dip can arm at most one nudge even if the gates
        // below then suppress it.
        if isEdge { next.pendingEdgeAt = nowSec }
        if !isBelow { next.pendingEdgeAt = 0 }

        func decide(_ nudge: Bool, _ reason: Reason) -> Decision {
            Decision(shouldNudge: nudge, reason: reason, buzzLoops: config.buzzLoops,
                     fastRMSSD: fast, baselineRMSSD: baseline, nextState: next,
                     stillnessVerified: stillVerified, baselineUpdated: restTick)
        }

        if !isBelow { return decide(false, .noDip) }
        // Nothing armed while below: the dip predates this run (e.g. state restored mid-dip) or its
        // arm was already consumed — either way there is no fresh crossing to act on.
        guard next.pendingEdgeAt != 0 else { return decide(false, .notAnEdge) }
        if nowSec - next.pendingEdgeAt < sustainSeconds { return decide(false, .awaitingSustain) }
        let armedAt = next.pendingEdgeAt
        next.pendingEdgeAt = 0   // consumed: proven sustained, now subject to the gates below

        // 5) Exercise gate (the credibility line), then the context gates. Either suppresses.
        if !hrInBand || moving { return decide(false, .exerciseGated) }
        if contextBlocks { return decide(false, .contextGated) }
        if afterTransition(nowSec) || afterTransition(armedAt) { return decide(false, .transitionGated) }

        // 6) Suppressors: a manual session is running, the rate limit, or quiet hours.
        if sessionActive { return decide(false, .suppressed) }
        if state.lastFireAt != 0 && (nowSec - state.lastFireAt) < minSecondsBetweenFires {
            return decide(false, .suppressed)
        }
        if config.quietHoursEnabled {
            let mod = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
            if SedentaryDetector.windowContains(mod, startMin: config.quietStartMinutes,
                                                endMin: config.quietEndMinutes) {
                return decide(false, .suppressed)
            }
        }

        // 7) Fire — a fresh, non-metabolic HRV dip (still only when `stillnessVerified`). Stamp the clock.
        next.lastFireAt = nowSec
        return decide(true, .onset)
    }

    // MARK: - Context from stored activity intervals

    /// How fresh the newest stored context run must be to speak for "now". Stored context lags the live
    /// stream (gravity is offloaded), so an older run is no evidence at all (`.none`), never "still".
    public static let contextMaxAgeSeconds: Int = 300

    /// The best available `LiveContext` from the stored activity-context intervals (any order).
    ///
    /// - `activity`: from the run covering `nowSec`, or the newest run ending within
    ///   `contextMaxAgeSeconds`: active / locomotion classes -> `.moving`; stationary classes (sitting,
    ///   standing, lying, stationary, fidgeting) -> `.still`; `unknown` / `off_wrist` -> `.unknown`;
    ///   `sleeping` -> `.still` with `asleep`. No fresh run -> `.none` (stillness unverified).
    /// - `lastTransitionAt`: the newest boundary between two adjacent runs whose posture family differs
    ///   (recumbent / seated / upright / active), the coarse transitions the wrist can support. A change
    ///   between `stationary` (posture unresolved) and a resolved posture is NOT counted: that is the
    ///   decoder resolving, not the body moving.
    /// - `lastExertionEndAt`: the end of the newest active / locomotion run that has ended.
    public static func liveContext(intervals: [ActivityContextInterval], nowSec: Int) -> LiveContext {
        let runs = intervals.filter { $0.end > $0.start && $0.start <= nowSec }.sorted { $0.start < $1.start }
        guard !runs.isEmpty else { return .none }
        func family(_ c: ActivityClass) -> String? {
            switch c {
            case .sleeping, .lyingDown: return "recumbent"
            case .sitting, .sittingDesk: return "seated"
            case .standing: return "upright"
            case .lightActivity, .walking, .briskWalking, .running, .cycling, .vigorousActivity: return "active"
            case .stationary, .fidgeting, .unknown, .offWrist: return nil
            }
        }
        func isActive(_ c: ActivityClass) -> Bool { family(c) == "active" }
        var ctx = LiveContext()
        let current = runs.last { $0.start <= nowSec && nowSec < $0.end }
            ?? runs.last { $0.end <= nowSec && nowSec - $0.end <= contextMaxAgeSeconds }
        if let c = current {
            switch c.activityClass {
            case .sleeping: ctx.activity = .still; ctx.asleep = true
            case .unknown, .offWrist: ctx.activity = .unknown
            default: ctx.activity = isActive(c.activityClass) ? .moving : .still
            }
        }
        var lastFamily: String? = nil
        for r in runs {
            guard let f = family(r.activityClass) else { continue }
            if let lf = lastFamily, lf != f, r.start <= nowSec { ctx.lastTransitionAt = r.start }
            lastFamily = f
        }
        ctx.lastExertionEndAt = runs.filter { isActive($0.activityClass) && $0.end <= nowSec }.map(\.end).max()
        return ctx
    }
}
