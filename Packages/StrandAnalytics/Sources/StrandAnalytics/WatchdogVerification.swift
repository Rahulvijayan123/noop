import Foundation
import WhoopStore

// WatchdogVerification.swift — the alert-verification contract (docs/BASELINE_WATCHDOG_V2.md §4).
//
// Detectors produce CANDIDATES; nothing notifies directly. Every candidate passes five checks before it may
// alert:
//   1. baseline      — compared against the right context (sleep / posture / walking) and an established,
//                      non-stale reference?
//   2. activity      — could movement, exercise, recovery, a posture change or a sleep transition explain it?
//   3. sensorQuality — strap on the body, optical/beat signal good, no motion artifact, known placement?
//   4. significance  — beyond ordinary variation for this person AND sustained?
//   5. independence  — are the abnormal channels independent evidence, or one heartbeat stream counted twice?
// Missing metadata is UNKNOWN, never good. UNKNOWN on a required check holds the candidate (shown, not sent).

// MARK: - Tri-state evidence

public enum WDOnBody: String, Equatable, Sendable, Codable { case on, off, unknown }
public enum WDSignal: String, Equatable, Sendable, Codable { case good, degraded, poor, unknown }
public enum WDMotion: String, Equatable, Sendable, Codable { case still, moving, artifact, unknown }

// MARK: - Quality feed (populated by WatchdogService from WhoopStore + live state)

/// Per-window sensor metadata. Every array may be empty; an empty array means UNKNOWN for what it would have
/// evidenced, never "fine".
public struct WatchdogQualityFeed: Equatable, Sendable {
    /// One v18 aux second (WHOOP 5/MG history record): `sentinel` = opticalAmpA/B == 128 OR hrQualityFlags
    /// bit 7 clear (bad optical second); `baselineZero` = opticalBaselineA == 0 && opticalBaselineB == 0
    /// (off-wrist optics); `spo2Pct` = aux byte @82 when 70…100.
    public struct V18Second: Equatable, Sendable, Codable {
        public var ts: Int
        public var sentinel: Bool
        public var baselineZero: Bool
        public var spo2Pct: Int?
        public init(ts: Int, sentinel: Bool, baselineZero: Bool, spo2Pct: Int? = nil) {
            self.ts = ts; self.sentinel = sentinel; self.baselineZero = baselineZero; self.spo2Pct = spo2Pct
        }
    }
    public struct WristEvent: Equatable, Sendable, Codable {
        public var ts: Int
        public var on: Bool
        public init(ts: Int, on: Bool) { self.ts = ts; self.on = on }
    }
    /// 0x2A37 sensor-contact state as stored (`unsupported` | `supported_not_detected` | `supported_detected`).
    public struct Contact: Equatable, Sendable, Codable {
        public var ts: Int
        public var state: String
        public init(ts: Int, state: String) { self.ts = ts; self.state = state }
    }
    public struct PpgHr: Equatable, Sendable, Codable {
        public var ts: Int
        public var bpm: Double
        public var conf: Double
        public init(ts: Int, bpm: Double, conf: Double) { self.ts = ts; self.bpm = bpm; self.conf = conf }
    }

    public var v18: [V18Second] = []
    /// WRIST_ON / WRIST_OFF events from the last 24 h (not just the 30-minute window), oldest first.
    public var wristEvents: [WristEvent] = []
    /// Live strap events since the app connected (a live WRIST_OFF / WRIST_ON).
    public var liveWristEvents: [WristEvent] = []
    /// nil = unknown (no battery packet). true = charging (strap is not on a body).
    public var charging: Bool? = nil
    public var contacts: [Contact] = []
    /// Logged placement for the window: "wrist" | "bicep" | "other"; nil = unknown (never assumed wrist).
    public var placement: String? = nil
    /// BOOT / RTC_LOST / BLE_SYSTEM_RESET timestamps in the last 24 h (wear state unknown until HR recovers).
    public var resetEvents: [Int] = []
    /// CH1/CH2/ACCEL saturation and AFE reset timestamps (signal POOR around them).
    public var saturationEvents: [Int] = []
    public var ppgHr: [PpgHr] = []
    /// The single R-R transport (srcChannel) stored beats were pinned to for this window; nil = none stored.
    public var rrTransport: Int? = nil
    /// Live beats were spliced only after this unix second (stored beats cover everything before it).
    public var rrLiveSplicedAfterTs: Int? = nil
    /// Seconds holding > 3000 ms of R-R after de-duplication (receipt-time pileups); POOR beat signal.
    public var rrPileupSeconds: [Int] = []
    /// Beats rejected as transport fill values (500 / 333 ms at HR < 100) in the window.
    public var rrFillRejected: Int = 0
    /// Duplicate beats removed before HRV (same identity, or live twin of a stored beat).
    public var rrDuplicatesRemoved: Int = 0
    /// Per window minute (key = minute start unix, aligned to the window grid `startUnix + i*60`): Σ R-R ms of
    /// the merged, de-duplicated beats ÷ 60 000. ≈ 1 when every beat was captured; < 0.5 or > 1.3 is POOR.
    /// Absent key = no beat information (UNKNOWN).
    public var rrCoverageByMinute: [Int: Double] = [:]
    /// Per window minute: number of seconds with a stored or live HR sample. Absent key = 0.
    public var hrSecondsByMinute: [Int: Int] = [:]
    /// Stored activity-context intervals (the phone's activity classification) overlapping the window, oldest
    /// first; used for posture / sleep / locomotion context. Empty = UNKNOWN context.
    public var contextIntervals: [ActivityContextIntervalRow] = []

    public init() {}

    public static let empty = WatchdogQualityFeed()
}

// MARK: - Per-minute assessment

public struct WatchdogMinuteQuality: Equatable, Sendable, Codable {
    public var minuteUnix: Int
    public var onBody: WDOnBody
    public var signal: WDSignal
    public var motion: WDMotion
    /// "wrist" | "bicep" | "other"; nil = unknown.
    public var placement: String?
    public var reasons: [String]
    public init(minuteUnix: Int, onBody: WDOnBody, signal: WDSignal, motion: WDMotion,
                placement: String?, reasons: [String]) {
        self.minuteUnix = minuteUnix; self.onBody = onBody; self.signal = signal; self.motion = motion
        self.placement = placement; self.reasons = reasons
    }
}

// MARK: - Candidates

public enum WatchdogCandidateKind: String, Equatable, Sendable, Codable {
    /// Physiological extreme against an absolute bound (sustained, quality-gated).
    case safetyExtreme = "safety_extreme"
    /// Sustained deviation from this person's context-matched Layer 1 reference.
    case personalDeviation = "personal_deviation"
    /// Anomaly window from the server models (TimesFM 3.0 forecast / UniTS reconstruction).
    case serverModel = "server_model"
}

/// Which physical sensing path a channel's value comes from. Channels in one group are NOT independent evidence.
public enum WatchdogSourceGroup: String, Equatable, Sendable, Codable, CaseIterable {
    /// HR, resting HR, HRV, and respiration derived from beat intervals: one optical heartbeat stream.
    case beatStream = "beat_stream"
    /// Optical SpO₂ (red/IR ratio) — same PPG sensor, different physics; partially independent.
    case opticalOxygen = "optical_oxygen"
    /// Wrist skin thermistor.
    case thermal
    /// Respiration from a respiration waveform (not from beats).
    case respirationWaveform = "respiration_waveform"
}

public struct WatchdogCandidate: Equatable, Sendable, Codable {
    public var kind: WatchdogCandidateKind
    public var id: String
    /// "HR" | "RHR" | "HRV" | "Temp" | "Resp" | "SpO2"
    public var channels: [String]
    public var startUnix: Int
    public var lastUnix: Int
    /// +1 above / −1 below the reference.
    public var direction: Int
    /// Robust z on the predictive scale (personal), the bound exceedance (safety) or model score.
    public var magnitude: Double
    /// Two-sided p of the sustained statistic when defined.
    public var p: Double?
    /// The Layer 1 series / stratum compared against (personal), the bound name (safety), the model (server).
    public var reference: String
    public var detail: [String: String]
    public init(kind: WatchdogCandidateKind, id: String, channels: [String], startUnix: Int, lastUnix: Int,
                direction: Int, magnitude: Double, p: Double? = nil, reference: String,
                detail: [String: String] = [:]) {
        self.kind = kind; self.id = id; self.channels = channels; self.startUnix = startUnix
        self.lastUnix = lastUnix; self.direction = direction; self.magnitude = magnitude; self.p = p
        self.reference = reference; self.detail = detail
    }
}

/// One anomaly window published by the VPS model service (`anomaly_candidates`), as fetched by the phone.
public struct WatchdogModelCandidate: Equatable, Sendable, Codable {
    public var candidateKey: String
    public var startUnix: Int
    public var endUnix: Int
    public var channels: [String]
    /// Per-model evidence: model id ("timesfm-3.0" / "units-x128") → calibrated two-sided p of the window.
    public var modelP: [String: Double]
    /// Models whose own calibrated p crossed their threshold.
    public var flaggedBy: [String]
    public var direction: Int
    public var score: Double
    public var severity: String
    public var status: String
    public var modelVersions: [String: String]
    public var computedAtUnix: Int
    public init(candidateKey: String, startUnix: Int, endUnix: Int, channels: [String], modelP: [String: Double],
                flaggedBy: [String], direction: Int, score: Double, severity: String, status: String,
                modelVersions: [String: String], computedAtUnix: Int) {
        self.candidateKey = candidateKey; self.startUnix = startUnix; self.endUnix = endUnix
        self.channels = channels; self.modelP = modelP; self.flaggedBy = flaggedBy; self.direction = direction
        self.score = score; self.severity = severity; self.status = status; self.modelVersions = modelVersions
        self.computedAtUnix = computedAtUnix
    }
}

// MARK: - Verdict

public enum WatchdogCheck: String, Equatable, Sendable, Codable, CaseIterable {
    case baseline, activity, sensorQuality = "sensor_quality", significance, independence
}

public enum WatchdogCheckOutcome: String, Equatable, Sendable, Codable {
    case pass, fail, unknown
    case notApplicable = "not_applicable"
}

public struct WatchdogCheckResult: Equatable, Sendable, Codable {
    public var check: WatchdogCheck
    public var outcome: WatchdogCheckOutcome
    public var reason: String
    public init(check: WatchdogCheck, outcome: WatchdogCheckOutcome, reason: String) {
        self.check = check; self.outcome = outcome; self.reason = reason
    }
}

public enum WatchdogVerdictDecision: String, Equatable, Sendable, Codable {
    /// Every required check passed: may notify (subject to the notify policy's cooldowns).
    case alert
    /// Plausible but unverified (an UNKNOWN check, immature baseline, not yet sustained): shown, not sent.
    case hold
    /// A check failed (explained by activity, poor signal, off body, ordinary variation …): not shown as Off.
    case suppress
}

public struct WatchdogVerdict: Equatable, Sendable, Codable {
    public var decision: WatchdogVerdictDecision
    public var candidate: WatchdogCandidate
    public var checks: [WatchdogCheckResult]
    public var independentGroups: Int
    /// A server model candidate overlaps this one (same channel group, same direction, within the window).
    public var modelCorroboration: [String]
    public var summary: String
    public init(decision: WatchdogVerdictDecision, candidate: WatchdogCandidate, checks: [WatchdogCheckResult],
                independentGroups: Int, modelCorroboration: [String], summary: String) {
        self.decision = decision; self.candidate = candidate; self.checks = checks
        self.independentGroups = independentGroups; self.modelCorroboration = modelCorroboration
        self.summary = summary
    }
}
