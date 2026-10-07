"""Metric definitions, mirrored from the app and the scoring tables (never re-derived here).

* `server_daily_scores` columns and units: 20260916160000_scoring_service_state.sql.
* Context-layer series families: MeasurementContextPage.seriesPrefixes (Strand/Screens/MeasurementContextWording.swift),
  also internal.metric_insight_series_prefixes in 20261008000000_metric_insights.sql.
* Whether a signal is measured or estimated: the context document's `availability` entries (reasons such as
  `rsa_only_estimate`, state `unverified`) decide at run time; `estimated` below is the default when a document
  has no entry for the signal.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Signal:
    key: str
    label: str
    column: str
    units: str
    decimals: int
    estimated: bool
    availability_metric: str | None = None
    # Stored values outside this range are not measurements (a 0 bpm night is a missing night, never a value).
    plausible: tuple[float, float] = (float("-inf"), float("inf"))
    # Display value = stored value x scale (sleep efficiency is stored as a fraction, shown as a percentage).
    scale: float = 1.0
    # Changes smaller than this (display units) read as "about the same".
    flat: float = 0.0


SIGNALS: dict[str, Signal] = {
    "resting_hr": Signal("resting_hr", "Resting heart rate", "resting_hr_bpm", "bpm", 0, False,
                         "resting_heart_rate", (25.0, 150.0), flat=1.0),
    "hrv_rmssd": Signal("hrv_rmssd", "HRV (RMSSD)", "hrv_rmssd_ms", "ms", 0, False, "hrv_rmssd", (1.0, 400.0),
                        flat=3.0),
    "resp_rate": Signal("resp_rate", "Respiratory rate", "resp_rate_bpm", "breaths/min", 1, True,
                        "respiratory_rate", (4.0, 40.0), flat=0.3),
    "skin_temp_dev": Signal("skin_temp_dev", "Skin temperature vs usual", "skin_temp_dev_c", "°C", 1, False,
                            "skin_temperature", (-5.0, 5.0), flat=0.1),
    "sleep_total": Signal("sleep_total", "Sleep duration", "sleep_total_min", "min", 0, True, None, (1.0, 1440.0),
                          flat=15.0),
    "sleep_efficiency": Signal("sleep_efficiency", "Sleep efficiency", "sleep_efficiency", "%", 0, True, None,
                               (0.01, 1.0), scale=100.0, flat=2.0),
    "spo2": Signal("spo2", "Blood oxygen", "spo2_pct", "%", 0, True, "spo2_candidate", (50.0, 100.0), flat=1.0),
}


@dataclass(frozen=True)
class InsightMetric:
    key: str
    signal: Signal
    series_prefixes: tuple[str, ...]
    nightly_series: str
    related: tuple[str, ...]


INSIGHT_METRICS: dict[str, InsightMetric] = {
    "resting_hr": InsightMetric("resting_hr", SIGNALS["resting_hr"], ("resting_hr.", "heart_rate."),
                                "resting_hr.sleep_night",
                                ("hrv_rmssd", "resp_rate", "skin_temp_dev", "sleep_total", "sleep_efficiency")),
    "hrv_rmssd": InsightMetric("hrv_rmssd", SIGNALS["hrv_rmssd"], ("hrv_rmssd.",), "hrv_rmssd.sleep_night",
                               ("resting_hr", "resp_rate", "skin_temp_dev", "sleep_total", "sleep_efficiency")),
}

# The scoring algorithm whose rows are the user's measured history (the only one in production).
ALGORITHM_VERSION = "frwhoop-server-1"
# Days of history an analysis covers, ending at the metric's latest measured day (the fingerprint's window).
WINDOW_DAYS = 90
# Below this many measured nights there is nothing to explain beyond "not enough data yet".
MIN_MEASURED_NIGHTS = 3
# The personal baseline: the measured nights before the latest, at most this many.
BASELINE_NIGHTS = 30

# Episode states and their rank, MeasurementContextSelection.episode (most notable first, newest among equals).
EPISODE_RANK = {"persistent_shift": 4, "recurring_episode": 3, "transient_deviation": 2,
                "insufficient_evidence": 1, "usual_variation": 0}
# Reference views in headline order, MeasurementContextSelection.headlineReference.
REFERENCE_ORDER = ("rolling", "recent", "frozen", "conditioned")


def plausible(signal: Signal, value: object) -> float | None:
    """The display value when the stored value is a real measurement of the signal, else None (missing, never
    zero)."""
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)  # numeric columns arrive as Decimal
    except (TypeError, ValueError):
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    low, high = signal.plausible
    return number * signal.scale if low <= number <= high else None
