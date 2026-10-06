"""Versioned initial operating defaults for sleep features (spec 4.1).

Every threshold here is a VERSIONED PROJECT DEFAULT, not a universal
physiological cutoff or clinically validated boundary. The whole object is
reported verbatim in the response's ``dependencies.config``.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict


@dataclass(frozen=True)
class SleepFeaturesConfig:
    # -- coverage gates (spec 4.2) --------------------------------------
    #: full-night continuity summary: >= 95% known timeline coverage
    continuity_known_fraction: float = 0.95
    #: no unresolved internal gap over 60 s
    continuity_max_gap_s: int = 60
    #: HR/temperature minute: >= 45 observed valid seconds at 1 Hz cadence
    minute_valid_seconds: int = 45
    #: curve fit: >= 75% valid bins, no interpolation across > 2-bin gaps
    curve_valid_bin_fraction: float = 0.75
    curve_max_interpolated_bins: int = 2
    #: stage-specific HRV: 5-minute windows, >= 80% temporal coverage,
    #: >= 100 valid adjacent pairs, <= 20% rejection fraction,
    #: >= 90% duration in the claimed stage
    stage_window_s: int = 300
    stage_hrv_coverage: float = 0.80
    stage_hrv_min_pairs: int = 100
    stage_hrv_max_rejected_fraction: float = 0.20
    stage_purity_fraction: float = 0.90
    #: stage-specific summary: >= 2 independent usable windows
    stage_min_windows: int = 2
    #: RSA interval variability: >= 20 estimated breath intervals per usable
    #: 5-minute window, >= 80% run coverage
    breath_min_intervals_per_window: int = 20
    breath_run_coverage: float = 0.80
    #: architecture entropy: >= 100 eligible adjacent pairs
    entropy_min_pairs: int = 100
    #: SRI gates (spec A3): >= 5 monitored valid days, >= 4 day-equivalents
    #: (96 h) of valid paired minutes, >= 80% of otherwise eligible pairs
    sri_min_valid_days: int = 5
    sri_min_paired_minutes: int = 4 * 1440
    sri_min_pair_fraction: float = 0.80
    #: history days loaded per request (spec 7.4: at most 31)
    history_days: int = 31
    #: thermal breakpoint gates (spec A6)
    thermal_min_minutes_per_side: int = 15
    thermal_min_rss_improvement: float = 0.20
    thermal_min_post_slope_c_per_min: float = 0.005
    thermal_min_sustained_c: float = 0.10
    #: cosinor / IS / IV gates (spec A6)
    rhythm_min_days: int = 5
    rhythm_day_coverage: float = 0.80
    #: settling plateau gates (spec A5)
    settling_slope_bpm_per_min: float = 0.1
    settling_mad_bpm: float = 2.0
    #: SRI withheld when the repository cannot establish a valid daytime
    #: decision; timing variability is still delivered from eligible nights.
    # (marker only; the policy is implemented in features/regularity.py)

    def to_wire(self) -> dict:
        return asdict(self)


CONFIG = SleepFeaturesConfig()
CONFIG_VERSION = "sleep-features-defaults-1"
