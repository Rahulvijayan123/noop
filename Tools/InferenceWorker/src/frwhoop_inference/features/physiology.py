"""Stage-conditioned physiology (spec A4) and shared window helpers.

Computes the per-night ``stage_physiology`` block (contract doc section 3):
per stage (``wake``/``light``/``deep``/``rem``) HR median + p10/p90,
5-minute window RMSSD/SDNN median + IQR, respiration median rate + variability,
skin-temperature median + MAD, and honest ``not_applicable`` entries for
movement (the request carries no gravity-change stream) and stage-conditioned
oxygen (B1 gate).

Processing order (spec A4, contract 4.2):

1. Split the night's beats into CONTIGUOUS source runs with the production
   run detector (``providers.hrv.continuous_runs``). Every REM beat is NOT
   concatenated into one segment.
2. Tile the night into 5-minute tumbling windows anchored at ``night.start``
   (half-open ``[t, t+300)``, last window clipped to the night end).
3. Clean each window's beats per run with the PRODUCTION cleaner
   (``clean_rr_gap_aware``); missing/rejected beats and run boundaries break
   adjacency exactly like the production provider. RMSSD and SDNN pool the
   per-run cleaned intervals (``rmssd_gap_aware``, ``sdnn``).
4. Label each window by the timeline's majority stage and require at least
   ``cfg.stage_purity_fraction`` of the window duration in the claimed stage;
   a mixed-stage window is EXCLUDED and its duration is counted in
   ``excluded_mixed_stage_min``.
5. Per-window gates: >= ``cfg.stage_hrv_coverage`` temporal coverage,
   >= ``cfg.stage_hrv_min_pairs`` valid adjacent pairs, <=
   ``cfg.stage_hrv_max_rejected_fraction`` rejection fraction, and the purity
   gate above.
6. Aggregate window-level RMSSD/SDNN with median + IQR per stage; HR and
   skin temperature per stage from MINUTE-level valid values (a minute is
   valid with >= ``cfg.minute_valid_seconds`` observed seconds at ~1 Hz; time
   support, not row counts).

Honesty rules (spec A4 / 4.3): every numeric leaf is finite or absent;
zero events on a complete trace is a valid 0; missing evidence is null + a
machine-readable reason; stage-conditioned HRV does not independently prove
autonomic changes (``model_dependent: true``).
"""

from __future__ import annotations

import statistics
from typing import Any, Sequence

import numpy as np

from ..providers.hrv import (
    HrvTuning,
    clean_rr_gap_aware,
    continuous_runs,
    rmssd_gap_aware,
    sdnn,
)
from .config import SleepFeaturesConfig
from .contract import KNOWN_STAGES, SleepFeaturesRequest, json_finite, metric_status
from .timeline import Timeline

# ---------------------------------------------------------------------------
# Shared window helpers (also used by features/respiration.py, spec A7)
# ---------------------------------------------------------------------------


def tumbling_windows(night_start: int, night_end: int, window_s: int):
    """Half-open ``[t, t+window_s)`` windows anchored at ``night_start``.

    The final window is clipped to ``night_end``; windows never extend past
    the night.
    """
    t = night_start
    while t < night_end:
        end = min(t + window_s, night_end)
        yield t, end
        t += window_s


def stage_coverage(tl: Timeline, t0: int, t1: int) -> tuple[str | None, dict[str, float]]:
    """(majority known stage, per-stage exact seconds) over ``[t0, t1)``.

    The majority is by exact segment-intersection seconds from the canonical
    timeline; ``None`` when no known stage covers the interval (e.g. an
    unresolved ``uns`` gap)."""
    durations: dict[str, float] = {}
    for stage in KNOWN_STAGES:
        d = tl.seconds_between(t0, t1, (stage,))
        if d > 0.0:
            durations[stage] = d
    if not durations:
        return None, {}
    stage = max(durations, key=durations.get)
    return stage, durations


def majority_stage(tl: Timeline, t0: int, t1: int,
                   purity_fraction: float) -> tuple[str | None, float]:
    """Label a window by the timeline majority stage.

    Returns ``(stage, purity)`` where purity is the claimed stage's fraction of
    the window duration. ``stage`` is ``None`` when no known stage covers the
    window OR the majority falls below ``purity_fraction`` (a mixed-stage or
    uncovered window).
    """
    stage, durations = stage_coverage(tl, t0, t1)
    if stage is None:
        return None, 0.0
    total = float(max(t1 - t0, 1))
    purity = durations[stage] / total
    if purity < purity_fraction:
        return None, purity
    return stage, purity


# ---------------------------------------------------------------------------
# Window-level HRV (production cleaning semantics)
# ---------------------------------------------------------------------------


def _analyze_window(run_segments: Sequence[Sequence[float]], window_s: int,
                    tuning: HrvTuning) -> dict[str, Any]:
    """Clean one window's beats per run and pool adjacency-aware RMSSD/SDNN.

    ``run_segments`` is the window's beats split by contiguous source run
    (order preserved). Each segment is cleaned with the production cleaner;
    adjacency is intact only between beats that were adjacent in the source
    AND survived cleaning, so an ectopic, a missing beat (wall-clock hole) or a
    run boundary breaks adjacency exactly like ``analyze_window``.
    """
    n_input = sum(len(seg) for seg in run_segments)
    window_ms = float(window_s) * 1000.0
    clean_nn: list[float] = []
    contiguous_all: list[bool] = []
    n_range = 0
    n_ectopic = 0
    for values in run_segments:
        nn, contiguous, n_range_out, n_ectopic_out = clean_rr_gap_aware(values, tuning)
        n_range += n_range_out
        n_ectopic += n_ectopic_out
        clean_nn.extend(nn)
        contiguous_all.extend(contiguous)
    rmssd, valid_pairs, _gap_excluded = rmssd_gap_aware(clean_nn, contiguous_all)
    n_clean = len(clean_nn)
    clean_beat_ms = float(sum(clean_nn))
    coverage = min(1.0, clean_beat_ms / window_ms) if window_ms > 0 else 0.0
    rejected_fraction = (1.0 - n_clean / n_input) if n_input else 0.0
    return {
        "n_input": n_input,
        "n_clean": n_clean,
        "n_range_rejected": n_range,
        "n_ectopic_rejected": n_ectopic,
        "valid_pairs": valid_pairs,
        "coverage": coverage,
        "rejected_fraction": rejected_fraction,
        "rmssd": rmssd,
        "sdnn": sdnn(clean_nn),
    }


def _window_gate(outcome: dict[str, Any], cfg: SleepFeaturesConfig) -> str | None:
    """Per-window usability gate (spec 4.2). None = usable, else a reason."""
    if outcome["rmssd"] is None or outcome["sdnn"] is None:
        return "insufficient_clean_beats"
    if outcome["coverage"] < cfg.stage_hrv_coverage:
        return "low_coverage"
    if outcome["valid_pairs"] < cfg.stage_hrv_min_pairs:
        return "insufficient_pairs"
    if outcome["rejected_fraction"] > cfg.stage_hrv_max_rejected_fraction:
        return "high_rejected_fraction"
    return None


# ---------------------------------------------------------------------------
# Minute-level time support (count seconds, not rows)
# ---------------------------------------------------------------------------


def night_minutes(night_start: int, night_end: int):
    """Yield ``(minute, clipped_start, clipped_end)`` for every minute the
    night overlaps, clipped to ``[night_start, night_end)``."""
    m0 = night_start // 60
    m1 = (night_end - 1) // 60
    for m in range(m0, m1 + 1):
        s = max(m * 60, night_start)
        e = min((m + 1) * 60, night_end)
        yield m, s, e


def _bucket(items: Sequence[Any], width: int, origin: int = 0) -> dict[int, list[Any]]:
    """Group ``items`` by ``(ts - origin) // width`` once, keeping their order.

    The per-minute and per-window scans below used to filter the whole night's
    samples for every minute/window (480 x 28,800 rows): ~4 s on the 4 vCPU
    Droplet against the 3 s budget. Each caller still re-applies its exact
    half-open ``[t0, t1)`` bounds to the (tiny) bucket, so results are identical.
    """
    out: dict[int, list[Any]] = {}
    for item in items:
        out.setdefault((item.ts - origin) // width, []).append(item)
    return out


def minute_stage(tl: Timeline, s: int, e: int) -> str | None:
    """Strict-majority stage over a minute's ``[s, e)`` span, or ``None``."""
    durations: dict[str, float] = {}
    for stage in KNOWN_STAGES:
        d = tl.seconds_between(s, e, (stage,))
        if d > 0.0:
            durations[stage] = d
    if not durations:
        return None
    total = float(max(e - s, 1))
    stage = max(durations, key=durations.get)
    return stage if durations[stage] > total / 2.0 else None


# ---------------------------------------------------------------------------
# Aggregation helpers
# ---------------------------------------------------------------------------


def _median(values: Sequence[float]) -> float | None:
    return float(statistics.median(values)) if values else None


def _iqr(values: Sequence[float]) -> float | None:
    if len(values) < 2:
        return None
    q75 = float(np.percentile(values, 75))
    q25 = float(np.percentile(values, 25))
    return q75 - q25


def _percentile(values: Sequence[float], p: float) -> float | None:
    if not values:
        return None
    return float(np.percentile(values, p))


def _mad(values: Sequence[float]) -> float | None:
    if not values:
        return None
    med = statistics.median(values)
    return float(statistics.median(abs(v - med) for v in values))


# ---------------------------------------------------------------------------
# Per-stage entry
# ---------------------------------------------------------------------------


def _stage_entry(stage: str, windows: Sequence[dict[str, Any]],
                 hr_minutes: Sequence[float], temp_minutes: Sequence[float],
                 excluded_mixed_min: float, cfg: SleepFeaturesConfig) -> dict[str, Any]:
    n_win = len(windows)
    rmssd_vals = [w["rmssd"] for w in windows if w.get("rmssd") is not None]
    sdnn_vals = [w["sdnn"] for w in windows if w.get("sdnn") is not None]
    resp_rates = [w["resp_median_bpm"] for w in windows
                  if w.get("resp_median_bpm") is not None]
    resp_cvs = [w["resp_cv"] for w in windows if w.get("resp_cv") is not None]

    reasons: list[str] = []
    if n_win == 0:
        status = "withheld"
        reasons.append("no_windows")
    elif n_win < cfg.stage_min_windows:
        status = "partial"
        reasons.append("thin_data")
    else:
        status = "available"
    if not hr_minutes:
        reasons.append("no_valid_hr_minutes")
    if not temp_minutes:
        reasons.append("no_valid_temp_minutes")
    if not resp_rates:
        reasons.append("no_respiratory_evidence_in_windows")
    if status == "available" and len(reasons) > 0:
        status = "partial"

    return {
        "status": status,
        "reasons": reasons,
        "hr_median_bpm": json_finite(_median(hr_minutes)),
        "hr_p10_bpm": json_finite(_percentile(hr_minutes, 10)),
        "hr_p90_bpm": json_finite(_percentile(hr_minutes, 90)),
        "rmssd_ms": {
            "median": json_finite(_median(rmssd_vals)),
            "iqr": json_finite(_iqr(rmssd_vals)),
            "windows": n_win,
        },
        "sdnn_ms": {
            "median": json_finite(_median(sdnn_vals)),
            "iqr": json_finite(_iqr(sdnn_vals)),
            "windows": n_win,
        },
        "resp_median_bpm": json_finite(_median(resp_rates)),
        "resp_variability_cv": json_finite(_median(resp_cvs)),
        "skin_temp_median_c": json_finite(_median(temp_minutes)),
        "skin_temp_mad_c": json_finite(_mad(temp_minutes)),
        "movement_events_per_h": None,
        "movement_detector": "1hz_gravity_change_stream",
        "movement": metric_status("not_applicable", ["movement_stream_not_in_request"]),
        "oxygen": metric_status("not_applicable", ["oxygen_unverified_sparse"]),
        "valid_min": len(hr_minutes),
        "windows": n_win,
        "excluded_mixed_stage_min": json_finite(excluded_mixed_min),
        "thin_data": 0 < n_win < cfg.stage_min_windows,
    }


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def compute_night(req: SleepFeaturesRequest, tl: Timeline,
                  cfg: SleepFeaturesConfig) -> dict[str, Any]:
    """Per-night ``stage_physiology`` block (contract doc section 3)."""
    start, end = tl.night.start, tl.night.end
    beats = [b for b in req.beats if start <= b.ts < end]
    tuning = HrvTuning()
    runs = continuous_runs(beats, tuning.splice_tolerance_s)

    stage_windows: dict[str, list[dict[str, Any]]] = {s: [] for s in KNOWN_STAGES}
    excluded_mixed_min: dict[str, float] = {s: 0.0 for s in KNOWN_STAGES}

    window_s = cfg.stage_window_s
    run_buckets = [_bucket(run, window_s, start) for run in runs]
    breath_buckets = _bucket(req.breaths, window_s, start)
    temp_buckets = _bucket(req.temp, window_s, start)

    for k, (t0, t1) in enumerate(tumbling_windows(start, end, window_s)):
        win_s = t1 - t0
        run_segments: list[list[float]] = []
        for buckets in run_buckets:
            vals = [b.rr_ms for b in buckets.get(k, ()) if t0 <= b.ts < t1]
            if vals:
                run_segments.append(vals)
        if not run_segments:
            continue
        outcome = _analyze_window(run_segments, win_s, tuning)
        stage, purity = majority_stage(tl, t0, t1, cfg.stage_purity_fraction)
        if stage is None:
            majority, _ = stage_coverage(tl, t0, t1)
            if majority is not None:
                # a majority exists but purity fell below the gate: count the
                # excluded mixed-stage duration for that stage
                excluded_mixed_min[majority] += win_s / 60.0
            continue
        if _window_gate(outcome, cfg) is not None:
            continue
        info: dict[str, Any] = {
            "t0": t0,
            "t1": t1,
            "rmssd": outcome["rmssd"],
            "sdnn": outcome["sdnn"],
            "valid_pairs": outcome["valid_pairs"],
            "n_clean": outcome["n_clean"],
            "coverage": outcome["coverage"],
            "rejected_fraction": outcome["rejected_fraction"],
        }
        breaths = [b for b in breath_buckets.get(k, ()) if t0 <= b.ts < t1]
        if len(breaths) >= 2:
            ds = sorted(b.seconds for b in breaths)
            med = statistics.median(ds)
            mean = sum(ds) / len(ds)
            sd = statistics.stdev(ds)
            if med > 0:
                info["resp_median_bpm"] = 60.0 / med
            if mean > 0:
                info["resp_cv"] = sd / mean
        temp_vals = [s.celsius for s in temp_buckets.get(k, ()) if t0 <= s.ts < t1]
        if temp_vals:
            info["temp_median"] = statistics.median(temp_vals)
        stage_windows[stage].append(info)

    # Minute-level HR / temperature per stage (time support, not rows).
    hr_minutes: dict[str, list[float]] = {s: [] for s in KNOWN_STAGES}
    temp_minutes: dict[str, list[float]] = {s: [] for s in KNOWN_STAGES}
    hr_by_minute = _bucket(req.hr, 60)
    temp_by_minute = _bucket(req.temp, 60)
    for m, ms, me in night_minutes(start, end):
        hr_in = [s for s in hr_by_minute.get(m, ()) if ms <= s.ts < me]
        if len({s.ts for s in hr_in}) >= cfg.minute_valid_seconds:
            stage = minute_stage(tl, ms, me)
            if stage is not None:
                vals = [s.bpm for s in hr_in]
                if vals:
                    hr_minutes[stage].append(float(statistics.median(vals)))
        temp_in = [s for s in temp_by_minute.get(m, ()) if ms <= s.ts < me]
        if len({s.ts for s in temp_in}) >= cfg.minute_valid_seconds:
            stage = minute_stage(tl, ms, me)
            if stage is not None:
                vals = [s.celsius for s in temp_in]
                if vals:
                    temp_minutes[stage].append(float(statistics.median(vals)))

    stages_block: dict[str, dict[str, Any]] = {}
    block_reasons: list[str] = []
    any_not_withheld = False
    for stage in KNOWN_STAGES:
        entry = _stage_entry(stage, stage_windows[stage], hr_minutes[stage],
                             temp_minutes[stage], excluded_mixed_min[stage], cfg)
        stages_block[stage] = entry
        if entry["status"] != "available":
            for r in entry["reasons"]:
                block_reasons.append(f"stage_{stage}:{r}")
        if entry["status"] != "withheld":
            any_not_withheld = True

    if not any_not_withheld:
        block_status = "withheld"
    elif block_reasons:
        block_status = "partial"
    else:
        block_status = "available"

    return {
        "status": block_status,
        "reasons": sorted(set(block_reasons)),
        "stage_source": "sleep-v2",
        "model_dependent": True,
        "stages": stages_block,
        "notes": ("Stage-conditioned physiology is model-dependent (sleep-v2 stages are "
                  "estimates); stage-conditioned HRV does not independently prove autonomic "
                  "changes. No clinical claim is made."),
    }
