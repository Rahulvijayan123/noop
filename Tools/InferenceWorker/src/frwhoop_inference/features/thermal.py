"""Temperature transitions and observed skin-temperature rhythm (spec section A6;
contract section 3 thermal).

Owner: worker-settling. Pure functions; every return is a JSON wire block.

Minute temperature = median of the request\'s supported skin-temperature samples inside
``[s + m*60, s + (m+1)*60)``; a minute is valid by TIME SUPPORT (>= ``cfg.minute_valid_seconds``
distinct observed seconds). The request carries no charging/wear evidence per sample, so
charging-interval exclusion cannot be applied in this wave (flagged in notes).

The thermal-rise transition is an EXPLORATORY bounded two-line breakpoint search, not an
established sleep-onset detector. Wrist skin temperature also moves with room temperature,
bedding, contact, medication or fever; no vasodilation, core temperature or causation is
inferred from the wrist channel alone.

The multi-day observed rhythm is a separately named sub-block (existing CircadianEngine
untouched). Since spec-02 it is computed by ``features/rhythm.py`` from the request's bounded
``rhythm_history`` (hourly UTC bins of converted skin temperature, worn HR and movement,
aggregated near the source by the worker) on the MAIN night only; naps carry
``not_applicable`` and a request without the history keeps
``multi_day_history_not_requested``. The pure helpers below (``cosinor_fit``,
``interdaily_stability``, ``intradaily_variance``, ``rhythm_gate``) remain for complete,
consecutive day grids; ``intradaily_variance`` now includes the day-boundary pairs.
"""

from __future__ import annotations

import math
import statistics
from collections import defaultdict
from typing import Any, Iterable, Sequence

import numpy as np
from scipy.stats import theilslopes

from .config import CONFIG, SleepFeaturesConfig
from . import rhythm
from .contract import NightIn, SleepFeaturesRequest, json_finite
from .timeline import Timeline, actual_sleep_onset, final_sleep_end

#: Minimum valid minutes for any windowed median / slope (same convention as the
#: settling block: "thin_data" always means fewer than this many valid minutes).
MIN_VALID_MINUTES = 4
#: Supported 5-minute windows need >= 4 valid minutes of the 5 (spec A6).
PEAK_MIN_SUPPORTED_MINUTES = 4
PEAK_WINDOW_MIN = 5
#: Pre-wake slope uses the final 30 valid minutes before final wake (spec A6).
PRE_WAKE_LAST_MINUTES = 30

BASELINE_SPAN = (-45, -15)
EARLY_SLEEP_SPAN = (30, 60)
RISE_SPAN = (0, 30)
BREAKPOINT_SPAN = (-45, 45)

#: Amplitude below which the cosinor phase is undefined (flat signal -> null).
_AMP_EPS = 1e-9
#: Relative variance below which R2 / IS / IV denominators count as zero.
_VAR_EPS = 1e-12


# ---------------------------------------------------------------------------
# Minute binning helpers (shared shape with features/settling.py)
# ---------------------------------------------------------------------------


def _minute_medians(
    ts_values: Iterable[tuple[int, float]], s: int, lo_min: int, hi_min: int
) -> dict[int, tuple[float | None, int]]:
    values: dict[int, list[float]] = defaultdict(list)
    seconds: dict[int, set[int]] = defaultdict(set)
    lo_ts = s + lo_min * 60
    hi_ts = s + hi_min * 60
    for ts, value in ts_values:
        if lo_ts <= ts < hi_ts:
            m = (ts - s) // 60
            values[m].append(float(value))
            seconds[m].add(int(ts))
    out: dict[int, tuple[float | None, int]] = {}
    for m in range(lo_min, hi_min):
        out[m] = (statistics.median(values[m]) if m in values else None, len(seconds[m]))
    return out


def _mad(values: Sequence[float]) -> float:
    med = statistics.median(values)
    return statistics.median([abs(v - med) for v in values])


def _theil_slope(xs: Sequence[float], ys: Sequence[float]) -> float | None:
    if len(xs) < 2 or len(ys) < 2:
        return None
    res = theilslopes(list(ys), list(xs))
    slope = float(res.slope)
    return slope if math.isfinite(slope) else None


def _valid_temps(
    medians: dict[int, tuple[float | None, int]], cfg: SleepFeaturesConfig
) -> dict[int, float]:
    return {
        m: float(medians[m][0])
        for m, (value, seconds) in medians.items()
        if value is not None and seconds >= cfg.minute_valid_seconds
    }


# ---------------------------------------------------------------------------
# Cosinor + rhythm pure functions (unit-tested even though the multi-day block
# is withheld in this wave)
# ---------------------------------------------------------------------------


def cosinor_fit(hourly_bins: Sequence[tuple[float, float]]) -> dict[str, Any]:
    """Fit y = M + a*cos(2*pi*t/24) + b*sin(2*pi*t/24) to balanced hourly bins.

    ``hourly_bins``: ``(t_hours, temperature_c)`` pairs, t measured from a known
    reference. Returns mesor_c, amplitude_c, acrophase_h (skin-temperature phase,
    hours, modulo 24), fit_quality (R2), n_bins. A flat signal yields a null
    acrophase and null fit quality (zero variance, never a divide by zero).
    """
    bins = [(float(t), float(v)) for t, v in hourly_bins if v is not None]
    out: dict[str, Any] = {"n_bins": len(bins), "mesor_c": None, "amplitude_c": None,
                           "acrophase_h": None, "fit_quality": None}
    if len(bins) < 3:
        return out
    ts = [t for t, _ in bins]
    ys = [v for _, v in bins]
    design = np.column_stack([
        np.ones(len(bins)),
        np.cos(2.0 * np.pi * np.asarray(ts) / 24.0),
        np.sin(2.0 * np.pi * np.asarray(ts) / 24.0),
    ])
    coef, *_ = np.linalg.lstsq(design, np.asarray(ys), rcond=None)
    mesor, a, b = float(coef[0]), float(coef[1]), float(coef[2])
    amplitude = math.sqrt(a * a + b * b)
    out["mesor_c"] = json_finite(mesor)
    out["amplitude_c"] = json_finite(amplitude)
    if amplitude > _AMP_EPS:
        out["acrophase_h"] = json_finite((math.atan2(b, a) * 24.0 / (2.0 * math.pi)) % 24.0)
    pred = (mesor
            + a * np.cos(2.0 * np.pi * np.asarray(ts) / 24.0)
            + b * np.sin(2.0 * np.pi * np.asarray(ts) / 24.0))
    rss = float(np.sum((np.asarray(ys) - pred) ** 2))
    tss = float(np.sum((np.asarray(ys) - statistics.mean(ys)) ** 2))
    if tss > _VAR_EPS:
        out["fit_quality"] = json_finite(1.0 - rss / tss)
    return out


def rhythm_gate(day_bins: Sequence[Sequence[float | None]],
                cfg: SleepFeaturesConfig = CONFIG) -> dict[str, Any]:
    """Gate for the 24-hour observed rhythm.

    ``day_bins``: one sequence per day of 24 entries (temperature or None) by local
    hour. Requirements (spec A6): >= cfg.rhythm_min_days days with >=
    cfg.rhythm_day_coverage whole-day coverage, and observation in every 6-hour
    quadrant (a nocturnal-only trace is insufficient -> withheld
    ``insufficient_daytime_temperature``).
    """
    qualifying = 0
    quadrant_seen = [False, False, False, False]
    for day in day_bins:
        supported = [i for i, v in enumerate(day) if v is not None]
        if supported:
            for i in supported:
                quadrant_seen[i // 6] = True
        if len(supported) / 24.0 >= cfg.rhythm_day_coverage:
            qualifying += 1
    reasons: list[str] = []
    if qualifying < cfg.rhythm_min_days:
        reasons.append("insufficient_days")
    if not all(quadrant_seen):
        reasons.append("insufficient_daytime_temperature")
    return {
        "status": "withheld" if reasons else "available",
        "reasons": reasons,
        "qualifying_days": qualifying,
        "quadrants_observed": quadrant_seen,
    }


def interdaily_stability(hourly_by_day: Sequence[Sequence[float]]) -> float | None:
    """IS = (n/p) * sum_h((mean_at_hour_h - global_mean)^2) / sum_t((x_t - global_mean)^2).

    ``hourly_by_day``: complete days, each with all 24 hourly bins (spec A6: IS/IV
    require complete balanced days; no gap-filling). p = 24, n = observed hourly-bin
    count. Zero overall variance -> None (never a divide by zero).
    """
    days = [list(d) for d in hourly_by_day]
    if not days or any(len(d) != 24 for d in days):
        return None
    all_vals = [v for d in days for v in d]
    n = len(all_vals)
    global_mean = statistics.mean(all_vals)
    denom = sum((x - global_mean) ** 2 for x in all_vals)
    if denom <= _VAR_EPS:
        return None
    num = 0.0
    for h in range(24):
        mean_h = statistics.mean(d[h] for d in days)
        num += (mean_h - global_mean) ** 2
    return (n / 24.0) * num / denom


def intradaily_variance(hourly_by_day: Sequence[Sequence[float]]) -> float | None:
    """IV = (n/(n-1)) * sum_t((x_{t+1}-x_t)^2) / sum_t((x_t - global_mean)^2).

    ``hourly_by_day``: CONSECUTIVE complete days of 24 hourly bins. The series is the days
    joined in order, so the 23:00 -> 00:00 pairs across midnight are consecutive hours and
    count (spec-02: the earlier variant dropped every day-boundary pair, which is not the
    standard full-series IV). Equal to ``rhythm.intradaily_variability`` on the same grid
    (n - 1 valid pairs). Zero overall variance -> None.
    """
    days = [list(d) for d in hourly_by_day]
    if not days or any(len(d) != 24 for d in days):
        return None
    all_vals = [v for d in days for v in d]
    n = len(all_vals)
    global_mean = statistics.mean(all_vals)
    denom = sum((x - global_mean) ** 2 for x in all_vals)
    if denom <= _VAR_EPS:
        return None
    num = sum((all_vals[i + 1] - all_vals[i]) ** 2 for i in range(n - 1))
    return (n / (n - 1.0)) * num / denom


# ---------------------------------------------------------------------------
# Thermal-rise breakpoint search
# ---------------------------------------------------------------------------


def _ols_fit(xs: Sequence[float], ys: Sequence[float]) -> tuple[float, float]:
    """Least-squares (slope, intercept); RSS is minimized by construction."""
    mean_x = statistics.mean(xs)
    mean_y = statistics.mean(ys)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    if sxx <= _VAR_EPS:
        return 0.0, mean_y
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / sxx
    intercept = mean_y - slope * mean_x
    return slope, intercept


def _rss(xs: Sequence[float], ys: Sequence[float], slope: float, intercept: float) -> float:
    return sum((y - (slope * x + intercept)) ** 2 for x, y in zip(xs, ys))


def find_thermal_transition(
    valid: dict[int, float], cfg: SleepFeaturesConfig
) -> dict[str, Any]:
    """Bounded two-line breakpoint search over [-45, +45] minutes (spec A6).

    ``valid``: minute-index -> temperature for minutes whose time support clears the
    gate. Candidates are breakpoints on VALID minute boundaries (the split minute must
    itself be a supported minute) with >= cfg.thermal_min_minutes_per_side valid
    minutes on each side. The search maximizes RSS improvement (OLS, the natural
    objective for residual sums of squares); the reported post-break slope is refit
    robustly with Theil-Sen. Returns the transition wire object.
    """
    if not valid:
        return {
            "onset_min": None, "rss_single": None, "rss_split": None,
            "improvement_pct": None, "post_slope_c_min": None, "sustained_c": None,
            "supported": False,
        }
    lo, hi = BREAKPOINT_SPAN
    minutes = sorted(valid)
    all_xs = [float(m) for m in minutes]
    all_ys = [valid[m] for m in minutes]

    slope1, intercept1 = _ols_fit(all_xs, all_ys)
    rss_single = _rss(all_xs, all_ys, slope1, intercept1)

    best: dict[str, Any] | None = None
    for b in minutes:
        if b <= lo or b > hi:
            continue
        left = [m for m in minutes if m < b]
        right = [m for m in minutes if m >= b]
        if len(left) < cfg.thermal_min_minutes_per_side or len(right) < cfg.thermal_min_minutes_per_side:
            continue
        lx = [float(m) for m in left]
        ly = [valid[m] for m in left]
        rx = [float(m) for m in right]
        ry = [valid[m] for m in right]
        s_l, i_l = _ols_fit(lx, ly)
        s_r, i_r = _ols_fit(rx, ry)
        rss_split = _rss(lx, ly, s_l, i_l) + _rss(rx, ry, s_r, i_r)
        if best is None or rss_split < best["rss_split"] - 1e-12:
            best = {
                "onset_min": b,
                "rss_split": rss_split,
                "left": left, "right": right,
                "left_ys": ly, "right_ys": ry,
                "right_xs": rx,
            }
        elif abs(rss_split - best["rss_split"]) <= 1e-12 and b < best["onset_min"]:
            best.update({"onset_min": b, "left": left, "right": right,
                         "left_ys": ly, "right_ys": ry, "right_xs": rx})

    if best is None:
        return {
            "onset_min": None, "rss_single": rss_single, "rss_split": None,
            "improvement_pct": None, "post_slope_c_min": None, "sustained_c": None,
            "supported": False,
        }

    improvement = (rss_single - best["rss_split"]) / rss_single if rss_single > _VAR_EPS else 0.0
    post_slope = _theil_slope(best["right_xs"], best["right_ys"])
    left_median = statistics.median(best["left_ys"])
    right_median = statistics.median(best["right_ys"])
    sustained = right_median - left_median
    pre_mad = _mad(best["left_ys"])
    threshold = max(cfg.thermal_min_sustained_c, 2.0 * pre_mad)

    supported = (
        post_slope is not None
        and improvement >= cfg.thermal_min_rss_improvement
        and post_slope >= cfg.thermal_min_post_slope_c_per_min
        and sustained >= threshold
    )
    return {
        "onset_min": json_finite(float(best["onset_min"])),
        "rss_single": json_finite(rss_single),
        "rss_split": json_finite(best["rss_split"]),
        "improvement_pct": json_finite(improvement * 100.0),
        "post_slope_c_min": json_finite(post_slope),
        "sustained_c": json_finite(sustained),
        "supported": supported,
        # additive transparency (spec A6: "Record all thresholds and residuals")
        "sustained_threshold_c": json_finite(threshold),
        "pre_transition_mad_c": json_finite(pre_mad),
        "n_left_valid": len(best["left"]),
        "n_right_valid": len(best["right"]),
    }


# ---------------------------------------------------------------------------
# Block assembly
# ---------------------------------------------------------------------------

NIGHTLY_NOTES = [
    "Exploratory breakpoint feature: NOT an established sleep-onset detector.",
    ("Wrist skin temperature also moves with room temperature, bedding, contact, "
     "medication or fever; no vasodilation, core temperature or causation is inferred "
     "from the wrist channel alone."),
    ("The request carries no charging/wear evidence per skin-temperature sample, so "
     "charging-interval exclusion is not applied in this wave; minute validity is "
     "time-support only."),
]

RHYTHM_NOTES = rhythm.RHYTHM_NOTES


def _rhythm_withheld_block() -> dict[str, Any]:
    """The rhythm sub-block when no multi-day history was requested."""
    return rhythm.not_requested_block()


def _rhythm_block(req: SleepFeaturesRequest, night: NightIn) -> dict[str, Any]:
    """The observed multi-day rhythm for this night, isolated from the nightly thermal
    block: a failure here withholds only the rhythm (``module_error``)."""
    try:
        return rhythm.observed_skin_temp_rhythm(req, night)
    except Exception as exc:  # noqa: BLE001 - isolation is the contract
        block = rhythm.not_requested_block()
        block["reasons"] = ["module_error"]
        block["phase_status"] = {"status": "unavailable", "reasons": ["module_error"]}
        block["error"] = f"{type(exc).__name__}: {exc}"
        return block


def _withheld_block(req: SleepFeaturesRequest, night: NightIn) -> dict[str, Any]:
    return {
        "status": "withheld",
        "reasons": ["no_sleep_onset"],
        "baseline_c": None,
        "early_sleep_delta_c": None,
        "rise_slope_c_min": None,
        "peak_latency_min": None,
        "pre_wake_slope_c_min": None,
        "thermal_transition": find_thermal_transition({}, CONFIG),
        "thermal_to_sleep_latency_min": None,
        "observed_skin_temp_rhythm": _rhythm_block(req, night),
        "notes": list(NIGHTLY_NOTES),
    }


def compute_night(
    req: SleepFeaturesRequest, tl: Timeline, cfg: SleepFeaturesConfig = CONFIG
) -> dict[str, Any]:
    """The per-night ``thermal`` block (contract section 3 thermal)."""
    s = actual_sleep_onset(tl)
    if s is None:
        return _withheld_block(req, tl.night)

    reasons: list[str] = []
    f = final_sleep_end(tl)
    f_min = ((f - s) // 60) + 2 if f is not None else 120
    medians = _minute_medians(((t.ts, t.celsius) for t in req.temp), s, -90, max(f_min, 120))
    valid = _valid_temps(medians, cfg)

    def window_values(lo: int, hi: int) -> list[float]:
        return [valid[m] for m in range(lo, hi) if m in valid]

    # --- baseline / early-sleep delta ---------------------------------------
    baseline = None
    base_vals = window_values(*BASELINE_SPAN)
    if len(base_vals) >= MIN_VALID_MINUTES:
        baseline = statistics.median(base_vals)
    if baseline is None:
        reasons.append("thin_data")

    early_delta = None
    early_vals = window_values(*EARLY_SLEEP_SPAN)
    if baseline is not None and len(early_vals) >= MIN_VALID_MINUTES:
        early_delta = statistics.median(early_vals) - baseline
    if early_delta is None:
        reasons.append("thin_data")

    # --- rise slope ----------------------------------------------------------
    rise = window_values(*RISE_SPAN)
    rise_slope = None
    if len(rise) >= MIN_VALID_MINUTES:
        xs = [float(m) for m in range(RISE_SPAN[0], RISE_SPAN[1]) if m in valid]
        rise_slope = _theil_slope(xs, rise)
    if rise_slope is None:
        reasons.append("thin_data")

    # --- peak latency (between onset and final wake) --------------------------
    peak_latency = None
    if f is not None:
        last_m = (f - s) // 60
        best_median = None
        for m in range(0, last_m - PEAK_WINDOW_MIN + 1):
            win = [valid[mi] for mi in range(m, m + PEAK_WINDOW_MIN) if mi in valid]
            if len(win) < PEAK_MIN_SUPPORTED_MINUTES:
                continue
            med = statistics.median(win)
            if best_median is None or med > best_median + 1e-9:
                best_median = med
                peak_latency = m
    else:
        reasons.append("no_final_wake")
    if peak_latency is None:
        reasons.append("thin_data")

    # --- pre-wake slope (final 30 valid minutes before final wake) -------------
    pre_wake_slope = None
    if f is not None:
        before = sorted((m for m in valid if m * 60 + s < f), reverse=True)
        last30 = sorted(before[:PRE_WAKE_LAST_MINUTES])
        if len(last30) >= MIN_VALID_MINUTES:
            pre_wake_slope = _theil_slope([float(m) for m in last30], [valid[m] for m in last30])
    if pre_wake_slope is None:
        reasons.append("thin_data")

    # --- thermal transition -----------------------------------------------------
    in_span = {m: valid[m] for m in valid if BREAKPOINT_SPAN[0] <= m <= BREAKPOINT_SPAN[1]}
    transition = find_thermal_transition(in_span, cfg)
    if not transition["supported"]:
        reasons.append("no_detectable_transition")

    thermal_to_sleep = None
    if transition["supported"] and transition["onset_min"] is not None:
        onset_ts = s + int(transition["onset_min"]) * 60
        thermal_to_sleep = (s - onset_ts) / 60.0  # sign preserved

    block = {
        "status": "partial" if reasons else "available",
        "reasons": sorted(set(reasons)),
        "baseline_c": json_finite(baseline),
        "early_sleep_delta_c": json_finite(early_delta),
        "rise_slope_c_min": json_finite(rise_slope),
        "peak_latency_min": json_finite(peak_latency),
        "pre_wake_slope_c_min": json_finite(pre_wake_slope),
        "thermal_transition": transition,
        "thermal_to_sleep_latency_min": json_finite(thermal_to_sleep),
        "observed_skin_temp_rhythm": _rhythm_block(req, tl.night),
        "notes": list(NIGHTLY_NOTES),
    }
    return block
