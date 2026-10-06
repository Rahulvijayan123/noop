import Foundation

/// Wear-state + signal-quality classification (spec `feat/wear-signal-quality`, V1).
///
/// A small deterministic evidence-fusion engine that answers, BEFORE downstream activity or
/// physiological interpretation: is the strap worn, is the contact usable, and are the optical
/// signals trustworthy enough to interpret? It is additive to `WearState`: the coarse three-state
/// fold stays the authority for existing enrichment, and `WearSignalState` is interpretation
/// context on top of it.
///
/// Design sources (research dir `research/wear-signal-quality/`): audits 01-04, red-team 08-11,
/// external research 05-07. The ladder below is the post-red-team synthesis (`00-final-design.md`).
///
/// Contract:
/// - PURE: DB-free, network-free, deterministic. Unit-testable with fixed vectors.
/// - The caller resolves evidence (including "freshness") and owns temporal state; the engine
///   consumes resolved booleans so live (45 s strap-domain) and offline/replay (interval
///   semantics) callers share one implementation (red-team 08: a wall-clock expiry on durable
///   events is wrong by construction because EVENT rows are banked on the uncorrected strap RTC).
/// - Missing evidence stays missing: `nil` never fabricates a decision; the engine abstains to
///   `unknown` aggressively rather than guessing (spec §6.6).
/// - SQI NEVER establishes wear (red-team 08/11): a beautiful waveform alone cannot say worn.
/// - Versioned: `WearSignalQualityEngine.version`; persisted results carry it for auditability.

/// The six target wear-signal states (spec §1).
public enum WearSignalState: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case onWristGood = "on_wrist_good"
    case onWristLoose = "on_wrist_loose"
    case motionArtifact = "motion_artifact"
    case offWrist = "off_wrist"
    case sensorDropout = "sensor_dropout"
    case unknown

    /// Coarse fold into the existing ActivityContext `WearState` (spec §9). The existing
    /// three-state enrichment remains untouched; this fold feeds it, never replaces it.
    public var coarseWear: WearState {
        switch self {
        case .onWristGood, .onWristLoose, .motionArtifact: return .onWrist
        case .offWrist: return .offWrist
        case .sensorDropout, .unknown: return .unknown
        }
    }

    /// Minimum V1 physiology gating for optical/RR-derived metrics (spec §10). nil = no change:
    /// `on_wrist_good` keeps the existing per-metric rules, and `unknown` preserves the existing
    /// metric-specific quality (never upgrades confidence, never fabricates a downgrade). Raw
    /// data is never deleted — interpretation is gated, storage is not.
    public var opticalMeasurementQuality: MeasurementQuality? {
        switch self {
        case .onWristGood, .unknown: return nil
        case .onWristLoose: return .uncertain
        case .motionArtifact: return .poor
        case .offWrist, .sensorDropout: return .unavailable
        }
    }
}

/// One epoch's resolved evidence. Every field is Optional: `nil` means the evidence is MISSING
/// (not false) — the engine never fabricates negative or positive evidence from absence, and
/// never lets a missing channel veto a hard assertion from a present one (spec §3).
public struct WearSignalEvidence: Equatable, Sendable {
    // - MARK: T1 explicit hardware/device wear evidence (spec §6.1)
    /// Live `WRIST_OFF`, fresh within the 45 s strap-domain gesture window (caller-resolved;
    /// see `FrameRouter.liveGestureWindowSeconds`). Highest authority: nothing overrides it.
    public let liveWristOffFresh: Bool?
    /// Live `WRIST_ON`, fresh within the 45 s strap-domain window (caller-resolved). Re-arms
    /// quality grading and starts the strap-adjustment grace.
    public let liveWristOnFresh: Bool?
    /// Interval semantics: the last durable `WRIST_OFF` from the `event` table has not been
    /// closed (no later `WRIST_ON`, no sustained-HR recovery, no charging transition). No
    /// wall-clock expiry — EVENT rows are banked on the uncorrected strap RTC (red-team 08).
    public let durableOffActive: Bool?
    /// Charger evidence (`CHARGING_ON`/`PACK` events, `battery.charging`): a docked strap is
    /// definitionally off-wrist (red-team 10 F4).
    public let charging: Bool?
    /// `WristWearRecovery.firstSustainedHR` criteria met (5 min run, <= 5 s gaps, 30-220 bpm):
    /// closes a durable off interval — the strap can go quiet with the link up (a 5.0 never
    /// sends `WRIST_OFF`), so sustained HR is the only exit path when `WRIST_ON` was missed.
    public let sustainedHrRecoveryMet: Bool?

    // - MARK: T2 stream/pulse presence
    /// Any plausible HR sample (30-220 bpm) this epoch.
    public let hrPresent: Bool?
    /// Pulse PRESENT but degraded (bad PPG window, contact flicker): a precondition for
    /// `on_wrist_loose` — never diagnose loose from a signal that is simply absent (red-team 09).
    public let pulseDegraded: Bool?
    /// WHOOP 5/MG `optical_baseline@106/107 == 0` with HR absent — empirically pinned in-tree
    /// as off-wrist (red-team 10 F1; warm-room table straps need more than temp).
    public let opticalBaselineZero: Bool?

    // - MARK: T2 strap's own validated quality flags (outrank derived SQI; red-team 09)
    /// Bad: `hr_quality_flags@36` bit7, `optical_amp@108/109` 128 sentinel, `onwrist@81` bad.
    public let strapFlagsBad: Bool?
    /// Good/valid strap flags — VETOES `on_wrist_loose` (the strap disagrees with our guess).
    public let strapFlagsValid: Bool?
    /// `STANDARD_HR_CONTACT` supported + not-detected (opportunistic: WHOOP does not emit it
    /// today; when a future device does, this is the best loose signal).
    public let contactNotDetected: Bool?

    // - MARK: T3 motion / temperature corroborators
    public let imuHighMotion: Bool?
    public let imuQuiet: Bool?
    /// Skin-like temperature (family-aware band): compatible-with-worn, NEVER evidence-of-worn
    /// (red-team 09: a dangled strap touching warm skin must not pass as worn).
    public let tempSkinLike: Bool?
    public let tempAmbientOrFalling: Bool?
    /// Battery telemetry rows stopped (battery-dead strap). NEVER off_wrist (red-team 08).
    public let batteryRowsStopped: Bool?
    /// RTC-reset span: events were dropped at ingest (#547) — evidence is untrustworthy.
    public let rtcResetSpan: Bool?
    /// Expected telemetry coverage below the minimum (record_index continuity), caller-resolved.
    /// Phone link-down with no strap-side evidence must NOT set this (transport is not sensor).
    public let streamsExpectedButAbsent: Bool?
    /// PPG waveform coverage adequate for quality grading this epoch.
    public let waveformCoverageAdequate: Bool?

    // - MARK: T4 derived optical quality + shadow (never establishes wear)
    /// 0...1 composite from `PpgSqi` (nil = waveform missing/unusable — never guessed).
    public let ppgSqi: Double?
    public let ppgSqiReasons: [String]
    /// Coverage-gated DETACH-style shadow (energy quiescence + raw-relative temp), AND-gated
    /// behind HR absence. NEVER decides a state alone (red-team 11 F6).
    public let detachShadowNonWear: Bool?

    public init(liveWristOffFresh: Bool? = nil,
                liveWristOnFresh: Bool? = nil,
                durableOffActive: Bool? = nil,
                charging: Bool? = nil,
                sustainedHrRecoveryMet: Bool? = nil,
                hrPresent: Bool? = nil,
                pulseDegraded: Bool? = nil,
                opticalBaselineZero: Bool? = nil,
                strapFlagsBad: Bool? = nil,
                strapFlagsValid: Bool? = nil,
                contactNotDetected: Bool? = nil,
                imuHighMotion: Bool? = nil,
                imuQuiet: Bool? = nil,
                tempSkinLike: Bool? = nil,
                tempAmbientOrFalling: Bool? = nil,
                batteryRowsStopped: Bool? = nil,
                rtcResetSpan: Bool? = nil,
                streamsExpectedButAbsent: Bool? = nil,
                waveformCoverageAdequate: Bool? = nil,
                ppgSqi: Double? = nil,
                ppgSqiReasons: [String] = [],
                detachShadowNonWear: Bool? = nil) {
        self.liveWristOffFresh = liveWristOffFresh
        self.liveWristOnFresh = liveWristOnFresh
        self.durableOffActive = durableOffActive
        self.charging = charging
        self.sustainedHrRecoveryMet = sustainedHrRecoveryMet
        self.hrPresent = hrPresent
        self.pulseDegraded = pulseDegraded
        self.opticalBaselineZero = opticalBaselineZero
        self.strapFlagsBad = strapFlagsBad
        self.strapFlagsValid = strapFlagsValid
        self.contactNotDetected = contactNotDetected
        self.imuHighMotion = imuHighMotion
        self.imuQuiet = imuQuiet
        self.tempSkinLike = tempSkinLike
        self.tempAmbientOrFalling = tempAmbientOrFalling
        self.batteryRowsStopped = batteryRowsStopped
        self.rtcResetSpan = rtcResetSpan
        self.streamsExpectedButAbsent = streamsExpectedButAbsent
        self.waveformCoverageAdequate = waveformCoverageAdequate
        self.ppgSqi = ppgSqi
        self.ppgSqiReasons = ppgSqiReasons
        self.detachShadowNonWear = detachShadowNonWear
    }
}

/// Versioned thresholds. `standard` is conservative: the CALIBRATE-marked values are
/// placeholder defaults with no labeled WHOOP ground truth behind them yet — the doc comments
/// say which are pinned by in-repo evidence and which need calibration captures.
public struct WearSignalQualityConfig: Equatable, Sendable {
    /// Sliding-window length (epochs) for the loose degraded-fraction (red-team 09: a flickering
    /// contact never produces N CONSECUTIVE bad windows; the fraction is the only robust form).
    public var looseWindowEpochs: Int = 6
    /// Degraded fraction over the sliding window that fires `on_wrist_loose`.
    public var looseDegradedFraction: Double = 0.6
    /// Schmitt enter for `motion_artifact` (epochs).
    public var artifactEnterEpochs: Int = 2
    /// Schmitt exit for `motion_artifact` (epochs; exit ALSO requires optical not degraded).
    public var artifactExitEpochs: Int = 2
    /// Grace epochs after a fresh `WRIST_ON`: no loose/artifact while the user adjusts the strap.
    public var graceEpochsAfterWristOn: Int = 3
    /// PPG SQI floor for "optical good". CALIBRATE (no labeled WHOOP data yet; 0.6 placeholder).
    public var sqiGoodMinimum: Double = 0.6
    public static let standard = WearSignalQualityConfig()
    public init() {}
    /// Algorithm version, persisted with every result for auditability.
    public let version: String = "wsq-1.0.0"
}

/// The classification result. `confidence` is a heuristic ordinal (not a calibrated probability —
/// no labeled ground truth exists yet; spec §14 forbids claiming accuracy without labels).
public struct WearSignalQualityResult: Codable, Equatable, Sendable {
    public let state: WearSignalState
    public let confidence: Double
    /// Short snake_case reason codes, one per contributing rule (`explicit_wrist_off`,
    /// `charging`, `optical_baseline_zero`, `hr_gap_offwrist_corroborated`,
    /// `hr_gap_worn_dropout`, `battery_dead`, `hr_gap_uncorroborated`, `not_worn_compatible`,
    /// `motion_artifact_entered`, `high_motion_optical_ok`, `loose_fraction_met`,
    /// `grace_active`, `good`, `sqi_missing_flags_valid`, `unknown_no_evidence`,
    /// `rtc_reset_span`, `charging_hr_conflict`, `durable_off_active`, `off_closed_recovery`).
    public let reasons: [String]
    public let coarseWear: WearState
    public let version: String

    public init(state: WearSignalState, confidence: Double, reasons: [String],
                coarseWear: WearState, version: String) {
        self.state = state
        self.confidence = max(0, min(1, confidence))
        self.reasons = reasons
        self.coarseWear = coarseWear
        self.version = version
    }
}

/// Caller-owned temporal state (hysteresis/debounce, spec §12). The engine stays pure: threading
/// the state explicitly keeps every classification reproducible from (evidence, state) pairs.
public struct WearSignalTemporalState: Equatable, Sendable {
    /// Per-epoch degraded flags for the loose sliding window (true = degraded).
    var looseWindow: [Bool] = []
    /// Consecutive degraded epochs entering `motion_artifact` (Schmitt).
    var artifactDegradedRun: Int = 0
    /// Consecutive clean epochs exiting `motion_artifact`.
    var artifactCleanRun: Int = 0
    var artifactActive: Bool = false
    /// Remaining grace epochs after a fresh `WRIST_ON`.
    var graceEpochsRemaining: Int = 0
    /// The durable-off interval was closed this epoch (recovery/ON/charging) — emitted once.
    var durableOffClosed: Bool = false
    var lastEpochStart: Int? = nil
    public init() {}

    /// Window length clamp (self-healing if the config changes mid-stream).
    mutating func clampWindow(to n: Int) {
        if looseWindow.count > n { looseWindow.removeFirst(looseWindow.count - n) }
    }
}

/// The pure six-state classifier. One call per 30-s epoch, in epoch order.
public enum WearSignalQualityEngine {

    /// Classify one epoch. Ladder order is authority: first match wins (00-final-design.md).
    public static func classify(_ e: WearSignalEvidence,
                                config: WearSignalQualityConfig = .standard,
                                state: inout WearSignalTemporalState,
                                epochStart: Int) -> WearSignalQualityResult {
        // A closure belongs to one durable-off interval; leaving it re-arms the off rule for the next.
        if e.durableOffActive != true { state.durableOffClosed = false }
        // Hysteresis bookkeeping common to all paths.
        advanceTemporal(&state, config: config, epochStart: epochStart,
                        freshOn: e.liveWristOnFresh == true,
                        offClosed: (e.sustainedHrRecoveryMet == true && e.tempSkinLike == true)
                            || e.liveWristOnFresh == true)

        func result(_ s: WearSignalState, _ conf: Double, _ reasons: [String]) -> WearSignalQualityResult {
            WearSignalQualityResult(state: s, confidence: conf, reasons: reasons,
                                    coarseWear: s.coarseWear, version: config.version)
        }

        // L0 — RTC reset / corrupt timestamps: evidence untrustworthy.
        if e.rtcResetSpan == true {
            return result(.unknown, 0.3, ["rtc_reset_span"])
        }

        // L1 — fresh live WRIST_OFF: nothing overrides explicit off (spec §6.1).
        if e.liveWristOffFresh == true {
            return result(.offWrist, 1.0, ["explicit_wrist_off"])
        }

        // L2 — durable off interval (interval semantics, no wall-clock expiry).
        if e.durableOffActive == true {
            // Closed this epoch by recovery + skin-like temp (or fresh ON handled in advance):
            if state.durableOffClosed {
                // Fall through to worn grading below (the off tail ends here).
            } else {
                return result(.offWrist, 0.95, ["durable_off_active"])
            }
        }

        // L3 — charging/docked is definitionally off-wrist; an HR conflict abstains (CALIBRATE:
        // does a docked 5/MG stream HR? Unknown, so the conflict goes to unknown, not a guess).
        if e.charging == true {
            if e.hrPresent == true {
                return result(.unknown, 0.5, ["charging_hr_conflict"])
            }
            return result(.offWrist, 1.0, ["charging"])
        }

        // L4 — WHOOP 5/MG optical baseline hard zero with HR absent (empirically pinned).
        if e.opticalBaselineZero == true && e.hrPresent != true {
            return result(.offWrist, 0.9, ["optical_baseline_zero"])
        }

        // L5 — dropout discrimination (spec §6.2): NEVER conflated with off_wrist.
        // Only when expected telemetry is absent; a phone link-down is not sensor dropout.
        let expectedAbsent = e.streamsExpectedButAbsent == true || e.hrPresent == false
        if expectedAbsent && e.hrPresent != true {
            if e.imuQuiet == true && e.tempAmbientOrFalling == true {
                return result(.offWrist, 0.7, ["hr_gap_offwrist_corroborated"])
            }
            if e.imuHighMotion == true || e.tempSkinLike == true {
                return result(.sensorDropout, 0.7, ["hr_gap_worn_dropout"])
            }
            if e.batteryRowsStopped == true {
                return result(.sensorDropout, 0.8, ["battery_dead"])
            }
            return result(.unknown, 0.4, ["hr_gap_uncorroborated"])
        }

        // L7 — worn-compatible gate. SQI NEVER establishes wear: a good waveform alone cannot
        // say worn (red-team 08/11). Quiet IMU alone NEVER proves on-wrist (spec §6, pinned by
        // ActivityContextPolicyTests): motion absence is not in this gate at all.
        let wornCompatible = e.liveWristOnFresh == true
            || (e.durableOffActive == false && e.durableOffActive != nil)
            || e.sustainedHrRecoveryMet == true
            || (e.hrPresent == true && e.tempSkinLike == true)
        guard wornCompatible else {
            return result(.unknown, 0.35, ["not_worn_compatible"])
        }

        // Optical quality resolved once (nil = missing; never fabricated).
        let sqi = e.ppgSqi
        let opticalDegraded = (sqi != nil && sqi! < config.sqiGoodMinimum)
            || e.strapFlagsBad == true
            || e.pulseDegraded == true
        let opticalGood = !opticalDegraded
            && (sqi == nil ? e.strapFlagsValid == true : sqi! >= config.sqiGoodMinimum)

        // L5b — grace after fresh WRIST_ON: allow good/unknown, never loose/artifact.
        if state.graceEpochsRemaining > 0 {
            if opticalGood && e.hrPresent == true && e.waveformCoverageAdequate != false {
                return result(.onWristGood, 0.7, ["good", "grace_active"])
            }
            return result(.unknown, 0.4, ["grace_active"])
        }

        // L7.5 — Schmitt exit bookkeeping for an active motion_artifact: exit requires
        // artifactExitEpochs consecutive optically-clean epochs (red-team 09 F4: symmetric
        // hysteresis, or HIIT toggles artifact<->good at 30-60 s cadence).
        if state.artifactActive {
            if opticalGood {
                state.artifactCleanRun += 1
                if state.artifactCleanRun >= config.artifactExitEpochs {
                    state.artifactActive = false
                    state.artifactDegradedRun = 0
                    state.artifactCleanRun = 0
                    // fall through: this epoch grades normally (good)
                } else {
                    return result(.motionArtifact, 0.7, ["motion_artifact_exit_pending"])
                }
            } else {
                state.artifactCleanRun = 0
                return result(.motionArtifact, 0.7, ["motion_artifact_active"])
            }
        }

        // L8 — motion artifact vs good (SPEC RULE 13.1#7: high motion + GOOD optical = good,
        // never artifact; the artifact needs degraded optical or a bad pulse).
        if e.imuHighMotion == true {
            if opticalDegraded {
                // Schmitt enter: consecutive degraded epochs, so a single corrupt window
                // during a workout does not flap the physiology gate.
                state.artifactDegradedRun += 1
                state.artifactCleanRun = 0
                if state.artifactDegradedRun >= config.artifactEnterEpochs {
                    state.artifactActive = true
                    return result(.motionArtifact, 0.75, ["motion_artifact_entered"])
                }
                return result(.unknown, 0.45, ["motion_artifact_pending", "high_motion_optical_degraded"])
            }
            state.artifactDegradedRun = 0
            // Motion alone is no optical evidence: without a resolved good optical verdict the
            // epoch abstains instead of grading good.
            guard opticalGood else {
                return result(.unknown, 0.4, ["high_motion_optical_unresolved"])
            }
            return result(.onWristGood, 0.8, ["good", "high_motion_optical_ok"])
        }

        // L9 — on_wrist_loose: multi-signal, fraction-based, pulse-present, conservative.
        // strapFlagsValid VETOES loose; artifact/dropout epochs PAUSE the window (advance already
        // paused them); skin-like temp alone is never evidence (compatible-with-worn only).
        let degradedThisEpoch = (sqi != nil && sqi! < config.sqiGoodMinimum)
            || e.strapFlagsBad == true
            || e.contactNotDetected == true
        if e.strapFlagsValid != true {
            // Sliding window INCLUDING this epoch (red-team 09: a flickering contact never
            // shows N consecutive bad windows; only the degraded fraction is robust).
            state.looseWindow.append(degradedThisEpoch)
            state.clampWindow(to: config.looseWindowEpochs)
            // Fire only over a FULL window (spec 13.1#8/#12: a single bad window must never
            // fire loose — a 1/1 filled fraction is 1.0, which is exactly that bug).
            let full = state.looseWindow.count >= config.looseWindowEpochs
            let fraction = full
                ? Double(state.looseWindow.filter { $0 }.count) / Double(state.looseWindow.count)
                : 0.0
            let pulsePresent = e.hrPresent == true || e.pulseDegraded == true
            // A DETACH-style non-wear shadow VETOES loose (never authoritative for off_wrist —
            // red-team 11 F6 — but a shadow of non-wear means "not confidently worn-loose", so
            // the engine abstains instead of claiming a worn-loose diagnosis).
            if full && fraction >= config.looseDegradedFraction && pulsePresent && degradedThisEpoch
                && e.detachShadowNonWear != true {
                return result(.onWristLoose, 0.75, ["loose_fraction_met"])
            }
        }

        // L10 — on_wrist_good.
        if e.hrPresent == true
            && e.waveformCoverageAdequate != false
            && (opticalGood || (sqi == nil && e.strapFlagsValid == true)) {
            var reasons = ["good"]
            if sqi == nil { reasons.append("sqi_missing_flags_valid") }
            return result(.onWristGood, sqi == nil ? 0.7 : 0.8, reasons)
        }

        // L11 — aggressive abstention (spec §6.6): unknown beats a wrong confident state.
        return result(.unknown, 0.3, ["insufficient_evidence"])
    }

    /// Temporal bookkeeping: grace countdown, Schmitt runs, pause-not-reset loose window,
    /// durable-off closure latching, data-gap confidence handling.
    private static func advanceTemporal(_ state: inout WearSignalTemporalState,
                                        config: WearSignalQualityConfig,
                                        epochStart: Int,
                                        freshOn: Bool,
                                        offClosed: Bool) {
        // Data gap: > 2 epochs since the last one — confidence in old accumulators drops; the
        // sliding windows reset (they are not comparable across a gap) but durable-off interval
        // semantics survive (they are caller-owned facts, not engine accumulators).
        if let last = state.lastEpochStart, epochStart - last > 90 {
            state.looseWindow = []
            state.artifactDegradedRun = 0
            state.artifactCleanRun = 0
            state.artifactActive = false
        }
        state.lastEpochStart = epochStart

        // Durable-off closure latches once (the caller sees it via the returned reason set).
        if offClosed { state.durableOffClosed = true }

        // Grace after a fresh WRIST_ON (strap adjustment period).
        if freshOn { state.graceEpochsRemaining = config.graceEpochsAfterWristOn }
        else if state.graceEpochsRemaining > 0 { state.graceEpochsRemaining -= 1 }

        // Schmitt runs are advanced by the caller-visible paths: entered/exited counters are
        // mutated in classify() where the optical verdict is known. Reset on a fresh ON.
        if freshOn {
            state.artifactDegradedRun = 0
            state.artifactActive = false
        }
    }
}
