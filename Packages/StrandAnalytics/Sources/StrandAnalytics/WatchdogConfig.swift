import Foundation

/// Frozen Watchdog / UniTS-AD knobs (`FRWHOOP_WATCHDOG.md`). Engineering defaults, not clinical limits.
public enum WatchdogConfig: Sendable {
    public static let seqLen = 30
    public static let gridSeconds = 60
    public static let contextSeconds = seqLen * gridSeconds
    public static let liveIntervals = [1, 2, 5, 10]
    public static let defaultLiveIntervalMinutes = 5
    /// How often the live baseline re-reads the strap. Not a patient control; each vital picks its own lookback.
    public static let tickSeconds = 20
    /// Second page (escalate) of the same episode. First severe of a new id is not muted.
    public static let notifyCooldownSeconds = 30 * 60

    public static let tau = 1.0
    public static let tauSevere = 2.0

    public static let whoop4MaxGapSeconds = 5
    public static let whoop5MaxGapSeconds = 90
    public static let whoop4FreshnessSeconds = 60
    public static let whoop5FreshnessSeconds = 90
    public static let minCoverage = 0.80

    public static let hrScale = 5.0
    public static let hrvScale = 8.0
    /// Wrist-skin half-width. Body-temp *structure* (personal usual ± a realistic delta),
    /// not core °C. 0.35 was a tight rail vs ambient wrist noise (~1 °C).
    public static let tempScale = 1.0
    public static let respScale = 3.0
    public static let spo2Scale = 2.0
    /// Occupancy / IMU below this is desk-still, not a walk. Chair fidget used to trip 0.15–0.18.
    public static let chairStillOccupancy = 0.32
    public static let chairStillDynMean = 0.22
    /// How fast this half-hour’s skin updates the personal setpoint (sleep prompt is the seed).
    public static let tempCenterAlpha = 0.28
    /// Resting HR uses still minutes in this trailing window, not the full 30-minute HR mix.
    public static let rhrLookbackSeconds = 10 * 60
    public static let spo2LookbackSeconds = 30 * 60

    public static let restHrHigh = 120.0
    public static let restHrLow = 35.0
    public static let tempLowC = 28.0
    public static let tempHighC = 38.0
    public static let respLow = 6.0
    public static let respHigh = 30.0
    public static let rmssdLow = 8.0
    public static let rmssdHigh = 250.0

    /// What the phone scores minutes against: the person's Layer 1 references by context (no on-device model).
    public static var expectationVersion: String { WatchdogExpectation.version }
    /// v3.1 (2026-10-08): the on-device "UniTS" / "TimesFM" Core ML stand-ins are removed; expectations are the
    /// person's own baselines and the only models are the real TimesFM 3.0 / UniTS on the VPS.
    /// v3.0 (audit 2026-10-07): verified candidates drive every decision (WatchdogVerifier.swift).
    public static let configVersion = "watchdog-v3.1"
    public static let activityFeatureWidth = 20
    public static let paramSet = "v1.review"

    public static let intervalKey = "noop.watchdog.liveIntervalMinutes"
    public static let lastNotifyKey = "noop.watchdog.lastNotifyUnix"
    public static let episodeIdKey = "noop.watchdog.episodeId"
    public static let mismatchTicksKey = "noop.watchdog.mismatchTicks"

    public static func clampInterval(_ minutes: Int) -> Int {
        liveIntervals.contains(minutes) ? minutes : defaultLiveIntervalMinutes
    }
}
