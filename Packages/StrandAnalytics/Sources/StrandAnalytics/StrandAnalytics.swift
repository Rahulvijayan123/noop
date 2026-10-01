import Foundation

/// On-device analytics for Strand (HRV, recovery, strain, sleep, workouts).
/// Ported from my-whoop's server/ingest/app/analysis/*.py — see plan Milestone 3.
///
/// Entry points (all pure, deterministic functions — no DB access):
///   - `HRZones`        — HR-max + 5 zones from age; time-in-zone from `[HRSample]`.
///   - `HRVAnalyzer`    — RMSSD / SDNN with range + Malik ectopic filtering.
///   - `Baselines`      — Winsorized-EWMA + trailing-window personal baselines.
///   - `RecoveryScorer` — resting HR + transparent 0–100 recovery composite.
///   - `StrainScorer`   — Edwards/Banister TRIMP → 0–21 logarithmic strain.
///   - `SleepStager`    — sleep/wake detection + APPROXIMATE 4-class staging.
///   - `WorkoutDetector`— elevated-HR workout detection + calories.
///   - `AnalyticsEngine`— orchestrator → `DailyMetric` + sleep-session results.
public enum StrandAnalytics {
    public static let version = "0.1.0"
}
