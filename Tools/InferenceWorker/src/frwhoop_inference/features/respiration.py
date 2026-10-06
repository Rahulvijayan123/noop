"""RSA-derived respiratory variability (spec A7).

Computes the per-night ``respiratory_variability`` block (contract doc section
3) from the Swift-computed ``SleepStager.respBreathTrack(rr)`` intervals and
runs, exported VERBATIM in the request (``req.breaths`` / ``req.breath_runs``).
No breath is recomputed in Python.

Processing:

1. Tile the night into the SAME 5-minute tumbling windows as A4 (anchored at
   ``night.start``) and label each window with the same timeline majority-stage
   rule and purity gate.
2. A window is usable when it holds >= ``cfg.breath_min_intervals_per_window``
   estimated breath intervals whose ``ts`` falls in the window AND >=
   ``cfg.breath_run_coverage`` of the window is covered by exported runs.
3. Night-level outputs pool the intervals of usable windows: ``rate_bpm =
   60/median(d)``, sample SD, CV = SD/mean, and ``rmssd_interval_s`` over
   ADJACENT intervals within the SAME usable run only (never across run
   boundaries, never from minute-rate summaries).
4. ``stage_conditioned`` pools the same windows per stage (never mixes stages
   into one distribution).
5. ``outlier_fraction_vs_personal`` is withheld in wave 1 (no personal
   baseline exists yet).

Honesty wording (spec A7): these are RSA-derived estimates; weak RSA,
ectopics, medication or missing R-R can erase estimated breaths without
airflow stopping; an unobserved breath is not an apnea; this is not measured
ventilation, tidal volume, central apnea or respiratory effort.
"""

from __future__ import annotations

import bisect
import math
import statistics
from typing import Any, Sequence

from .config import SleepFeaturesConfig
from .contract import KNOWN_STAGES, SleepFeaturesRequest, json_finite, metric_status
from .physiology import majority_stage, tumbling_windows
from .timeline import Timeline

#: The Swift entry point that produced the exported intervals/runs.
ALGORITHM_SOURCE = "SleepStager.respBreathTrack(rr)"


def _run_coverage_seconds(runs, t0: int, t1: int) -> float:
    """Exact seconds of ``[t0, t1)`` covered by the exported runs (half-open)."""
    total = 0.0
    for r in runs:
        s = max(r.start, t0)
        e = min(r.end, t1)
        if e > s:
            total += float(e - s)
    return total


def _run_of(ts: int, runs) -> int:
    """Index of the run containing ``ts`` (half-open membership), or -1."""
    for i, r in enumerate(runs):
        if r.start <= ts < r.end:
            return i
    return -1


def _pooled_metrics(ds: Sequence[float]) -> dict[str, Any]:
    """Night- or stage-level pooled metrics from estimated breath durations.

    ``ds`` is a non-empty list of seconds. rate_bpm = 60/median(d);
    sd_interval_s = sample SD; cv_interval = SD/mean; rmssd is NOT pooled here
    (adjacency is run-scoped and computed separately)."""
    median_d = statistics.median(ds)
    mean_d = sum(ds) / len(ds)
    sd = statistics.stdev(ds) if len(ds) >= 2 else None
    return {
        "rate_bpm": json_finite(60.0 / median_d) if median_d > 0 else None,
        "sd_interval_s": json_finite(sd),
        "cv_interval": json_finite(sd / mean_d) if (sd is not None and mean_d > 0) else None,
    }


def compute_night(req: SleepFeaturesRequest, tl: Timeline,
                  cfg: SleepFeaturesConfig) -> dict[str, Any]:
    """Per-night ``respiratory_variability`` block (contract doc section 3)."""
    start, end = tl.night.start, tl.night.end
    intervals = [b for b in req.breaths if start <= b.ts < end]
    runs = list(req.breath_runs)

    night_span = float(max(end - start, 1))
    night_run_seconds = _run_coverage_seconds(runs, start, end)

    # --- usable windows (breath gates + the same A4 stage labeling) --------
    usable: list[dict[str, Any]] = []
    total_windows = 0
    tss = [iv.ts for iv in intervals]
    for t0, t1 in tumbling_windows(start, end, cfg.stage_window_s):
        total_windows += 1
        lo = bisect.bisect_left(tss, t0)
        hi = bisect.bisect_left(tss, t1)
        w_intervals = intervals[lo:hi]
        if len(w_intervals) < cfg.breath_min_intervals_per_window:
            continue
        covered = _run_coverage_seconds(runs, t0, t1)
        if covered / float(t1 - t0) < cfg.breath_run_coverage:
            continue
        stage, _purity = majority_stage(tl, t0, t1, cfg.stage_purity_fraction)
        if stage is None:
            continue
        usable.append({
            "t0": t0,
            "t1": t1,
            "lo": lo,
            "hi": hi,
            "stage": stage,
            "run_covered_s": covered,
        })

    # --- usable interval set (indexes into the night's sorted intervals) ---
    n = len(intervals)
    usable_idx = [False] * n
    for w in usable:
        for i in range(w["lo"], w["hi"]):
            usable_idx[i] = True
    ds_usable = [intervals[i].seconds for i in range(n) if usable_idx[i]]

    reasons: list[str] = []
    if not intervals:
        block_status = "withheld"
        reasons.append("no_breath_intervals")
    elif not usable:
        block_status = "withheld"
        reasons.append("no_usable_windows")
    else:
        block_status = "available"

    # --- night-level outputs -------------------------------------------------
    rate_bpm: float | None = None
    sd_interval_s: float | None = None
    cv_interval: float | None = None
    rmssd_interval_s: float | None = None
    if ds_usable:
        pooled = _pooled_metrics(ds_usable)
        rate_bpm = pooled["rate_bpm"]
        sd_interval_s = pooled["sd_interval_s"]
        cv_interval = pooled["cv_interval"]
        if block_status == "available" and rate_bpm is None:
            block_status = "partial"
            reasons.append("median_interval_nonpositive")

    # rmssd_interval_s: adjacent intervals within the SAME usable run only.
    if ds_usable:
        run_ids = [_run_of(iv.ts, runs) for iv in intervals]
        diffs: list[float] = []
        prev = None
        for i in range(n):
            if not usable_idx[i]:
                prev = None  # an unusable interval breaks run-local adjacency
                continue
            if (prev is not None and run_ids[i] == run_ids[prev]
                    and i == prev + 1):
                d = intervals[i].seconds - intervals[prev].seconds
                diffs.append(d * d)
            prev = i
        if diffs:
            rmssd_interval_s = json_finite(math.sqrt(sum(diffs) / len(diffs)))
        elif block_status == "available":
            block_status = "partial"
            reasons.append("no_adjacent_pairs_within_runs")

    valid_run_min = json_finite(sum(w["run_covered_s"] for w in usable) / 60.0)

    # --- stage-conditioned pooling (never mix stages) ------------------------
    stage_conditioned: dict[str, dict[str, Any]] = {}
    for stage in KNOWN_STAGES:
        stage_windows = [w for w in usable if w["stage"] == stage]
        stage_ds = [
            intervals[i].seconds
            for w in stage_windows
            for i in range(w["lo"], w["hi"])
        ]
        entry: dict[str, Any] = {"windows": len(stage_windows)}
        if stage_ds:
            pooled = _pooled_metrics(stage_ds)
            entry["rate_bpm"] = pooled["rate_bpm"]
            entry["cv_interval"] = pooled["cv_interval"]
        else:
            entry["rate_bpm"] = None
            entry["cv_interval"] = None
        stage_conditioned[stage] = entry

    block_reasons = sorted(set(reasons))
    return {
        "status": block_status,
        "reasons": block_reasons,
        "estimate_source": "rsa_derived_rr",
        "unobserved_breath_is_not_apnea": True,
        "algorithm_source": ALGORITHM_SOURCE,
        "notes": ("RSA-derived estimates; weak RSA, ectopics, medication or missing R-R "
                  "can erase estimated breaths without airflow stopping; an unobserved "
                  "breath is not an apnea; not measured ventilation/tidal volume/"
                  "respiratory effort."),
        "intervals_valid": int(sum(usable_idx)),
        "rate_bpm": rate_bpm,
        "sd_interval_s": sd_interval_s,
        "cv_interval": cv_interval,
        "rmssd_interval_s": rmssd_interval_s,
        "valid_run_min": valid_run_min,
        "quality": {
            "usable_windows": len(usable),
            "total_windows": total_windows,
            "night_run_coverage": json_finite(night_run_seconds / night_span),
        },
        "stage_conditioned": stage_conditioned,
        "outlier_fraction_vs_personal": {
            **metric_status("withheld", ["no_personal_baseline"]),
            "fraction": None,
        },
    }
