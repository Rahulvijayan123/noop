"""Autonomic sleep-settling curves (spec section A5; contract section 3 settling).

Owner: worker-settling. Pure functions; every return is a JSON wire block.

Anchor t=0 at the canonical ACTUAL sleep onset ``s``
(``features.timeline.actual_sleep_onset``), never ``tl.night.start``. Minute HR and
skin-temperature values are medians of the request\'s samples inside each minute bin
``[s + m*60, s + (m+1)*60)``; a minute is VALID by TIME SUPPORT (>= ``cfg.minute_valid_seconds``
distinct observed seconds), never by row count (spec 4.2: "Count time support, not
retransmitted rows").

Slopes are Theil-Sen (``scipy.stats.theilslopes``). Theil-Sen confidence limits are NOT
reported here: ordinary confidence intervals do not account for serial correlation in a
minute-by-minute time series (spec A5).

The HRV early-sleep curve reuses the production cleaning semantics
(``providers.hrv.continuous_runs`` + ``clean_rr_gap_aware`` + pooled RMSSD), so the
settling curve and the canonical nightly HRV never disagree about what an ectopic or a
gap is.
"""

from __future__ import annotations

import math
import statistics
from collections import defaultdict
from typing import Any, Iterable, Sequence

from scipy.stats import theilslopes

from ..providers.hrv import HrvTuning, clean_rr_gap_aware, continuous_runs
from .config import CONFIG, SleepFeaturesConfig
from .contract import SleepFeaturesRequest, json_finite
from .timeline import Timeline, actual_sleep_onset

#: Minimum valid minutes for any windowed slope / median. Spec A5 fixes >= 4 for the
#: slopes; the same floor is applied to every other windowed estimate for consistency,
#: so "thin_data" always means the same thing inside this block.
MIN_VALID_MINUTES = 4
#: Settling plateau windows need >= 8 valid minutes out of 10 (spec A5).
SETTLING_MIN_VALID_MINUTES = 8
#: Nadir candidate windows need >= 4 supported minutes out of 5 (spec A5).
NADIR_MIN_SUPPORTED_MINUTES = 4
#: HRV curve needs >= 4 usable windows for a log-slope (spec A5).
HRV_MIN_WINDOWS = 4
#: Nadir candidate windows are 5 minutes wide (spec A5).
NADIR_WINDOW_MIN = 5

#: Window definitions, all in minutes relative to s.
PRE_SPAN = (-30, 0)
EARLY_SPAN = (0, 30)
DROP_PRE_SPAN = (-20, -5)
DROP_POST_SPAN = (15, 30)
NADIR_SPAN = (0, 90)
SETTLING_SPAN = (0, 90)
SETTLING_WINDOW_MIN = 10
HRV_SPAN = (0, 60)
HRV_WINDOW_MIN = 5
CURVE_SPAN = (-30, 90)


def _minute_medians(
    ts_values: Iterable[tuple[int, float]], s: int, lo_min: int, hi_min: int
) -> dict[int, tuple[float | None, int]]:
    """Median and distinct-observed-second count per minute bin over [lo_min, hi_min).

    Bins are ``[s + m*60, s + (m+1)*60)``. Time support is the number of DISTINCT
    timestamps observed in the minute (a dense retransmission does not create support).
    """
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
        if m in values:
            out[m] = (statistics.median(values[m]), len(seconds[m]))
        else:
            out[m] = (None, 0)
    return out


def _mad(values: Sequence[float]) -> float:
    """Median absolute deviation of a non-empty series."""
    med = statistics.median(values)
    return statistics.median([abs(v - med) for v in values])


def _theil_slope(xs: Sequence[float], ys: Sequence[float]) -> float | None:
    """Theil-Sen slope, or None when it is degenerate / non-finite."""
    if len(xs) < 2 or len(ys) < 2:
        return None
    res = theilslopes(list(ys), list(xs))
    slope = float(res.slope)
    return slope if math.isfinite(slope) else None


def _window_rmssd(beats, t_start: int, t_end: int, tuning: HrvTuning):
    """Production-semantics pooled RMSSD for one half-open 5-minute window.

    Returns (rmssd_ms | None, valid_pairs, coverage, clean_beat_ms).
    """
    in_window = [b for b in beats if t_start <= b.ts < t_end]
    window_ms = max(0, t_end - t_start) * 1000
    if not in_window:
        return None, 0, 0.0, 0.0
    sum_sq = 0.0
    pairs = 0
    clean_nn: list[float] = []
    runs = continuous_runs(in_window, tuning.splice_tolerance_s)
    for run in runs:
        values = [b.rr_ms for b in run]
        nn, contiguous, _n_range, _n_ectopic = clean_rr_gap_aware(values, tuning)
        clean_nn.extend(nn)
        for i in range(1, len(nn)):
            if contiguous[i]:
                delta = nn[i] - nn[i - 1]
                sum_sq += delta * delta
                pairs += 1
    clean_ms = sum(clean_nn)
    coverage = min(1.0, clean_ms / float(window_ms)) if window_ms > 0 else 0.0
    rmssd = math.sqrt(sum_sq / pairs) if pairs else None
    if rmssd is not None and not math.isfinite(rmssd):
        rmssd = None
    return rmssd, pairs, coverage, clean_ms


def _withheld_block() -> dict[str, Any]:
    return {
        "status": "withheld",
        "reasons": ["no_sleep_onset"],
        "hr_pre_onset_slope_bpm_min": None,
        "hr_early_sleep_slope_bpm_min": None,
        "hr_drop_bpm": None,
        "hr_nadir_latency_min": None,
        "hr_settling_latency_min": None,
        "hrv_early_sleep_curve": [],
        "hrv_early_sleep_log_slope_per_min": None,
        "hr_curve": [],
        "temp_curve": [],
    }


def compute_night(
    req: SleepFeaturesRequest, tl: Timeline, cfg: SleepFeaturesConfig = CONFIG
) -> dict[str, Any]:
    """The per-night ``settling`` block (contract section 3 settling)."""
    s = actual_sleep_onset(tl)
    if s is None:
        return _withheld_block()

    reasons: list[str] = []

    # --- minute medians ---------------------------------------------------
    hr_medians = _minute_medians(((h.ts, h.bpm) for h in req.hr), s, *CURVE_SPAN)
    temp_medians = _minute_medians(((t.ts, t.celsius) for t in req.temp), s, *CURVE_SPAN)
    hr_valid = {m for m, (v, sec) in hr_medians.items() if v is not None and sec >= cfg.minute_valid_seconds}
    temp_valid = {m for m, (v, sec) in temp_medians.items() if v is not None and sec >= cfg.minute_valid_seconds}

    def span_minutes(lo: int, hi: int, valid: set[int]) -> list[tuple[int, float]]:
        return [(m, float(hr_medians[m][0])) for m in range(lo, hi) if m in valid]

    # --- slopes ------------------------------------------------------------
    pre = span_minutes(*PRE_SPAN, hr_valid)
    early = span_minutes(*EARLY_SPAN, hr_valid)

    hr_pre_onset_slope = None
    if len(pre) >= MIN_VALID_MINUTES:
        hr_pre_onset_slope = _theil_slope([m for m, _ in pre], [v for _, v in pre])
    if hr_pre_onset_slope is None:
        reasons.append("thin_data")

    hr_early_sleep_slope = None
    if len(early) >= MIN_VALID_MINUTES:
        hr_early_sleep_slope = _theil_slope([m for m, _ in early], [v for _, v in early])
    if hr_early_sleep_slope is None:
        reasons.append("thin_data")

    # --- drop --------------------------------------------------------------
    pre_drop = span_minutes(*DROP_PRE_SPAN, hr_valid)
    post_drop = span_minutes(*DROP_POST_SPAN, hr_valid)
    hr_drop = None
    if len(pre_drop) >= MIN_VALID_MINUTES and len(post_drop) >= MIN_VALID_MINUTES:
        # contract: median HR[-20,-5) - median HR[+15,+30); a decline is a POSITIVE drop.
        hr_drop = statistics.median([v for _, v in pre_drop]) - statistics.median(
            [v for _, v in post_drop]
        )
    if hr_drop is None:
        reasons.append("thin_data")

    # --- nadir -------------------------------------------------------------
    hr_nadir_latency = None
    best_mean = None
    for m in range(NADIR_SPAN[0], NADIR_SPAN[1] - NADIR_WINDOW_MIN + 1):
        win = [(mi, hr_medians[mi][0]) for mi in range(m, m + NADIR_WINDOW_MIN)
               if mi in hr_valid]
        if len(win) < NADIR_MIN_SUPPORTED_MINUTES:
            continue
        mean = statistics.mean(v for _, v in win)
        if best_mean is None or mean < best_mean - 1e-9:
            best_mean = mean
            hr_nadir_latency = m
    if hr_nadir_latency is None:
        reasons.append("thin_data")

    # --- settling plateau ---------------------------------------------------
    hr_settling_latency = None
    for m in range(SETTLING_SPAN[0], SETTLING_SPAN[1] - SETTLING_WINDOW_MIN + 1):
        win = [(mi, hr_medians[mi][0]) for mi in range(m, m + SETTLING_WINDOW_MIN) if mi in hr_valid]
        if len(win) < SETTLING_MIN_VALID_MINUTES:
            continue
        xs = [float(mi) for mi, _ in win]
        ys = [v for _, v in win]
        slope = _theil_slope(xs, ys)
        if slope is None or abs(slope) > cfg.settling_slope_bpm_per_min:
            continue
        if _mad(ys) > cfg.settling_mad_bpm:
            continue
        hr_settling_latency = m
        break
    if hr_settling_latency is None:
        reasons.append("no_detected_plateau")

    # --- HRV early-sleep curve ----------------------------------------------
    tuning = HrvTuning()
    hrv_curve: list[dict[str, Any]] = []
    for m in range(HRV_SPAN[0], HRV_SPAN[1], HRV_WINDOW_MIN):
        t_start = s + m * 60
        rmssd, pairs, coverage, _clean_ms = _window_rmssd(req.beats, t_start, t_start + 300, tuning)
        if rmssd is None:
            continue
        hrv_curve.append({
            "ts": t_start,
            "rmssd_ms": json_finite(rmssd),
            "pairs": pairs,
            "coverage": json_finite(coverage),
        })

    hrv_log_slope = None
    # log(RMSSD) needs a POSITIVE RMSSD. A window of perfectly constant R-R
    # intervals yields RMSSD 0.0 (mathematically valid, log undefined); such a
    # window stays in the curve but is EXCLUDED from the log slope rather than
    # crashing the block (a fixture with a flat R-R series found this).
    log_points = [(e["ts"], e["rmssd_ms"]) for e in hrv_curve
                  if e["rmssd_ms"] is not None and e["rmssd_ms"] > 0.0]
    if len(log_points) >= HRV_MIN_WINDOWS:
        hrv_xs = [(ts - s) / 60.0 for ts, _ in log_points]
        hrv_ys = [math.log(v) for _, v in log_points]
        hrv_log_slope = _theil_slope(hrv_xs, hrv_ys)
    if hrv_log_slope is None:
        reasons.append("thin_data")

    # --- raw curves ----------------------------------------------------------
    hr_curve = [
        {
            "ts": s + m * 60,
            "bpm": json_finite(hr_medians[m][0]),
            "valid": m in hr_valid,
        }
        for m in range(CURVE_SPAN[0], CURVE_SPAN[1])
    ]
    temp_curve = [
        {
            "ts": s + m * 60,
            "celsius": json_finite(temp_medians[m][0]),
            "valid": m in temp_valid,
        }
        for m in range(CURVE_SPAN[0], CURVE_SPAN[1])
    ]

    block = {
        "status": "partial" if reasons else "available",
        "reasons": sorted(set(reasons)),
        "hr_pre_onset_slope_bpm_min": json_finite(hr_pre_onset_slope),
        "hr_early_sleep_slope_bpm_min": json_finite(hr_early_sleep_slope),
        "hr_drop_bpm": json_finite(hr_drop),
        "hr_nadir_latency_min": json_finite(hr_nadir_latency),
        "hr_settling_latency_min": json_finite(hr_settling_latency),
        "hrv_early_sleep_curve": hrv_curve,
        "hrv_early_sleep_log_slope_per_min": json_finite(hrv_log_slope),
        "hr_curve": hr_curve,
        "temp_curve": temp_curve,
    }
    return block
