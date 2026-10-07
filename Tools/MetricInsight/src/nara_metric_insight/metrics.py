"""Metric definitions, mirrored from the app and the scoring tables (never re-derived here). docs/METRIC_INSIGHTS.md
is the contract: one id per metric across the app, the edge function, the database and this worker.

* Where a value comes from (`Signal.source`): a `server_daily_scores` column (20260916160000_scoring_service_state.sql),
  a hosted day snapshot value (`public.metric_insight_day_values_v1`: steps, the day's energy, the strap's SpO2
  estimate), or a context-layer daily value (`calm_awake_hr_bpm` = `heart_rate.stable_awake_5min`).
* Context-layer series families: MeasurementContextPage.seriesPrefixes (Strand/Screens/MeasurementContextWording.swift).
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
    # scores (a server_daily_scores column) | day_values (a hosted day snapshot value) | context (a daily value)
    source: str = "scores"
    # The app's Baseline (Layer 1) series for this signal, when the app has one (layer1.SERIES).
    layer1: str | None = None


SIGNALS: dict[str, Signal] = {
    "resting_hr": Signal("resting_hr", "Resting heart rate", "resting_hr_bpm", "bpm", 0, False,
                         "resting_heart_rate", (25.0, 150.0), flat=1.0, layer1="sleep_rhr"),
    "hrv_rmssd": Signal("hrv_rmssd", "HRV (RMSSD)", "hrv_rmssd_ms", "ms", 0, False, "hrv_rmssd", (1.0, 400.0),
                        flat=3.0, layer1="sleep_hrv_ln"),
    "hrv_sdnn": Signal("hrv_sdnn", "HRV (SDNN)", "hrv_sdnn_ms", "ms", 0, False, "hrv_sdnn", (1.0, 400.0), flat=3.0),
    "resp_rate": Signal("resp_rate", "Respiratory rate", "resp_rate_bpm", "breaths/min", 1, True,
                        "respiratory_rate", (4.0, 40.0), flat=0.3, layer1="sleep_resp"),
    "skin_temp": Signal("skin_temp", "Wrist temperature", "skin_temp_c", "°C", 1, False, "skin_temperature",
                        (20.0, 42.0), flat=0.1, layer1="sleep_temp"),
    "skin_temp_dev": Signal("skin_temp_dev", "Skin temperature vs usual", "skin_temp_dev_c", "°C", 1, False,
                            "skin_temperature", (-5.0, 5.0), flat=0.1),
    "sleep_total": Signal("sleep_total", "Sleep duration", "sleep_total_min", "h", 1, True, None, (1.0, 1440.0),
                          scale=1 / 60, flat=0.25),
    "sleep_efficiency": Signal("sleep_efficiency", "Sleep efficiency", "sleep_efficiency", "%", 0, True, None,
                               (0.01, 1.0), scale=100.0, flat=2.0),
    # The strap's SpO2 is an unverified estimate (`daily.spo2_candidate_pct`); `spo2_pct` is never filled.
    "spo2": Signal("spo2", "Blood oxygen", "spo2_candidate_pct", "%", 0, True, "spo2_candidate", (70.0, 100.0),
                   flat=1.0, source="day_values"),
    "heart_rate": Signal("heart_rate", "Calm awake heart rate", "calm_awake_hr_bpm", "bpm", 0, False, "heart_rate",
                         (30.0, 200.0), flat=1.0, source="context"),
    # A worn day with no steps is a real 0; a day without step data has no value.
    "steps": Signal("steps", "Steps", "steps", "steps", 0, True, None, (0.0, 200000.0), flat=500.0,
                    source="day_values", layer1="waking_steps"),
    # The whole day's energy (resting + active), as the app's Calories metric shows it (activeKcalEst).
    "calories": Signal("calories", "Calories", "total_kcal", "kcal", 0, True, None, (1.0, 10000.0), flat=50.0,
                       source="day_values"),
}


@dataclass(frozen=True)
class InsightMetric:
    key: str
    signal: Signal
    # night: keyed by the day it ends | day: a complete local day (never today, still running)
    period: str
    series_prefixes: tuple[str, ...]
    # The context-layer series of the value itself, whose comparisons and change episodes speak about it.
    context_series: str | None
    related: tuple[str, ...]
    # app_baseline (Layer 1, `signal.layer1`) | context_layer (its reference and episodes) | recent (the last
    # measured periods: the app shows no usual for these)
    usual: str
    # The curated literature corpus' metric tag (literature.CORPUS), when it has entries for this metric.
    literature: str | None = None


INSIGHT_METRICS: dict[str, InsightMetric] = {m.key: m for m in (
    InsightMetric("resting_hr", SIGNALS["resting_hr"], "night", ("resting_hr.", "heart_rate."),
                  "resting_hr.sleep_night",
                  ("hrv_rmssd", "resp_rate", "skin_temp_dev", "sleep_total", "sleep_efficiency"), "app_baseline", "rhr"),
    InsightMetric("hrv_rmssd", SIGNALS["hrv_rmssd"], "night", ("hrv_rmssd.",), "hrv_rmssd.sleep_night",
                  ("hrv_sdnn", "resting_hr", "resp_rate", "skin_temp_dev", "sleep_total", "sleep_efficiency"),
                  "app_baseline", "hrv"),
    InsightMetric("hrv_sdnn", SIGNALS["hrv_sdnn"], "night", ("hrv_sdnn.",), None,
                  ("hrv_rmssd", "resting_hr", "resp_rate", "sleep_total", "sleep_efficiency"), "recent", "hrv"),
    InsightMetric("skin_temp", SIGNALS["skin_temp"], "night", ("skin_temp.",), "skin_temp.sleep_night",
                  ("skin_temp_dev", "resting_hr", "hrv_rmssd", "resp_rate", "sleep_total"), "app_baseline"),
    InsightMetric("resp_rate", SIGNALS["resp_rate"], "night", ("resp_rate.",), "resp_rate.sleep_night",
                  ("resting_hr", "hrv_rmssd", "skin_temp_dev", "sleep_total", "sleep_efficiency"), "app_baseline"),
    InsightMetric("spo2", SIGNALS["spo2"], "night", ("spo2.",), None,
                  ("resp_rate", "resting_hr", "sleep_total", "sleep_efficiency"), "recent"),
    InsightMetric("heart_rate", SIGNALS["heart_rate"], "day", ("heart_rate.",), "heart_rate.stable_awake_5min",
                  ("resting_hr", "hrv_rmssd", "steps", "sleep_total"), "context_layer", "rhr"),
    InsightMetric("steps", SIGNALS["steps"], "day", (), None, ("calories", "heart_rate", "sleep_total"),
                  "app_baseline"),
    InsightMetric("calories", SIGNALS["calories"], "day", (), None, ("steps", "heart_rate", "sleep_total"), "recent"),
)}


# The scoring algorithm whose rows are the user's measured history (the only one in production).
ALGORITHM_VERSION = "frwhoop-server-1"
# Days of history an analysis covers, ending at the metric's latest measured day (the fingerprint's window).
WINDOW_DAYS = 90
# Below this many measured nights (or days) there is nothing to explain beyond "not enough data yet".
MIN_MEASURED_NIGHTS = 3
# The personal baseline: the measured nights (or days) before the latest, at most this many.
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
