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

spec-02 additions (``method_version`` ``resp-variability-2``, docs/spec-02/CONTRACT.md 5.2):

6. ``supported_range``: what the detector can see at all (6-24 breaths/min band,
   2.5 s minimum peak spacing, displayed rate 8-25). No tachypnea/bradypnea,
   pause or apnea count is derived from it.
7. ``interval_distribution``: quantiles of TRUE consecutive breath intervals.
   An interval is true only when both of its peaks lie inside one exported run
   (``ts - seconds`` not before the run start, ``ts`` not after its end), so a
   gap between runs can never become a long breath. The set is the usable-window
   intervals of step 3, restricted to true intervals.
8. ``stable_modulation`` (``stable-resp-modulation-1``): every 5-minute window
   of the night is evaluated (enough run coverage and true intervals) or
   unknown; an evaluated window is stable when its interval CV is at or below
   the criterion. Unknown time is never stable, and the fraction of the night
   keeps the unknown time in its denominator.
9. ``stage_conditioned[stage]`` gains SD, RMSSD (adjacent true intervals of the
   same run), median and IQR of the stage's true intervals.
"""

from __future__ import annotations

import bisect
import math
import statistics
from dataclasses import asdict, dataclass
from typing import Any, Sequence

import numpy

from .config import SleepFeaturesConfig
from .contract import KNOWN_STAGES, SleepFeaturesRequest, json_finite, metric_status
from .physiology import majority_stage, tumbling_windows
from .timeline import Timeline

#: The Swift entry point that produced the exported intervals/runs.
ALGORITHM_SOURCE = "SleepStager.respBreathTrack(rr)"

#: spec-02 block version (docs/spec-02/CONTRACT.md 5.2).
METHOD_VERSION = "resp-variability-2"
STABLE_DEFINITION_VERSION = "stable-resp-modulation-1"


@dataclass(frozen=True)
class RespVariabilityConfig:
    """spec-02 parameters of this block (project defaults, not physiological cutoffs).

    Reported verbatim in the block's ``config``; ``features/config.py`` is unchanged so the
    document's ``dependencies.config`` stays stable."""
    #: interval_distribution needs at least this many usable windows (the stage-summary minimum).
    distribution_min_windows: int = 2
    #: quantiles reported (percent), linear interpolation (numpy default).
    distribution_percentiles: tuple = (5, 10, 25, 50, 75, 90, 95)
    #: stable modulation: evaluation window (the A4/A7 5-minute grid anchored at night start).
    stable_window_s: int = 300
    #: a window is evaluated when exported runs cover at least this share of it ...
    stable_min_run_coverage: float = 0.80
    #: ... and it holds at least this many true breath intervals (the A7 usable-window minimum).
    stable_min_intervals: int = 20
    #: an evaluated window is stable when the CV (sample SD / mean) of its true intervals is at or below this.
    stable_max_cv_interval: float = 0.25

    def to_wire(self) -> dict:
        d = asdict(self)
        d["distribution_percentiles"] = list(self.distribution_percentiles)
        return d


RESP_CONFIG = RespVariabilityConfig()

#: What the RSA breath detector can see (docs/spec-02/CONTRACT.md 5.2). Mirrors the Swift
#: constants: RespBreathTrack band 6-24 breaths/min with 2.5 s minimum peak spacing, and
#: SleepStager.respPlausibleRangeBpm 8...25 for every displayed rate.
SUPPORTED_RANGE = {
    "detector_band_bpm": [6.0, 24.0],
    "min_peak_spacing_s": 2.5,
    "display_rate_range_bpm": [8.0, 25.0],
    "source": "SleepStager.respBreathTrack",
}


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


def _true_run_ids(intervals, runs) -> list[int]:
    """Run index of each interval when BOTH of its peaks lie in that run, else -1.

    Runs are inclusive ``[start, end]`` wall-clock seconds (``RespBreathTrack.Run``); an interval is
    stamped at the floor second of its later peak, so its earlier peak lies in
    ``[ts - seconds, ts + 1 - seconds)``. The interval is accepted when that earlier peak can be
    inside the run (``ts + 1 - seconds >= start``) and its later peak is (``ts <= end``). A
    pseudo-interval spanning the gap between two runs fails the first test, so a gap is never a
    long breath."""
    starts = [r.start for r in runs]
    out: list[int] = []
    for iv in intervals:
        k = bisect.bisect_right(starts, iv.ts) - 1
        if k >= 0 and iv.ts <= runs[k].end and iv.ts + 1 - iv.seconds >= runs[k].start:
            out.append(k)
        else:
            out.append(-1)
    return out


def _percentile(ds: Sequence[float], q: float) -> float | None:
    return json_finite(float(numpy.percentile(numpy.asarray(ds, dtype=float), q))) if ds else None


def _iqr(ds: Sequence[float]) -> float | None:
    if not ds:
        return None
    q25, q75 = numpy.percentile(numpy.asarray(ds, dtype=float), [25, 75])
    return json_finite(float(q75 - q25))


def _rmssd_adjacent(indexes: Sequence[int], intervals, run_ids: Sequence[int]) -> float | None:
    """RMSSD over pairs of CONSECUTIVE intervals (index i-1, i) that are both in ``indexes`` and
    in the same run; nothing is paired across a run boundary or across an excluded interval."""
    chosen = set(indexes)
    diffs: list[float] = []
    for i in sorted(chosen):
        j = i - 1
        if j in chosen and run_ids[i] >= 0 and run_ids[i] == run_ids[j]:
            d = intervals[i].seconds - intervals[j].seconds
            diffs.append(d * d)
    return json_finite(math.sqrt(sum(diffs) / len(diffs))) if diffs else None


def _interval_distribution(ds: Sequence[float], usable_windows: int,
                           rcfg: RespVariabilityConfig) -> dict[str, Any]:
    """``interval_distribution``: quantiles of true usable intervals (seconds)."""
    reasons: list[str] = []
    if not ds:
        status = "withheld"
        reasons.append("no_true_intervals_in_usable_windows")
    elif usable_windows < rcfg.distribution_min_windows:
        status = "withheld"
        reasons.append("insufficient_usable_windows")
    else:
        status = "available"
    have = status == "available"
    pct = {q: (_percentile(ds, q) if have else None) for q in rcfg.distribution_percentiles}
    return {
        "status": status,
        "reasons": reasons,
        "n_intervals": len(ds),
        "usable_windows": usable_windows,
        "median_s": pct.get(50),
        "iqr_s": _iqr(ds) if have else None,
        "p05_s": pct.get(5),
        "p10_s": pct.get(10),
        "p25_s": pct.get(25),
        "p75_s": pct.get(75),
        "p90_s": pct.get(90),
        "p95_s": pct.get(95),
        "unit": "s",
        "quantile_method": "linear_interpolation",
        "source": "consecutive_intervals_within_usable_runs",
    }


def _stable_modulation(start: int, end: int, intervals, true_ids: Sequence[int], runs,
                       rcfg: RespVariabilityConfig) -> dict[str, Any]:
    """``stable_modulation`` (``stable-resp-modulation-1``).

    Every window of the night grid is either EVALUATED (run coverage >= criterion AND >= the
    minimum number of true intervals) or UNKNOWN. An evaluated window is STABLE when the CV of its
    true intervals is <= the criterion. Unknown windows never count as stable; the night fraction
    keeps them in its denominator. Stage labels are not used (stability is a breathing-signal
    property, and the stages are themselves estimated)."""
    tss = [iv.ts for iv in intervals]
    evaluated_s = 0.0
    stable_s = 0.0
    windows_evaluated = 0
    windows_stable = 0
    windows_total = 0
    for t0, t1 in tumbling_windows(start, end, rcfg.stable_window_s):
        windows_total += 1
        span = float(t1 - t0)
        lo = bisect.bisect_left(tss, t0)
        hi = bisect.bisect_left(tss, t1)
        ds = [intervals[i].seconds for i in range(lo, hi) if true_ids[i] >= 0]
        covered = _run_coverage_seconds(runs, t0, t1)
        if covered / span < rcfg.stable_min_run_coverage or len(ds) < rcfg.stable_min_intervals:
            continue
        windows_evaluated += 1
        evaluated_s += span
        mean_d = sum(ds) / len(ds)
        cv = statistics.stdev(ds) / mean_d if (len(ds) >= 2 and mean_d > 0) else None
        if cv is not None and cv <= rcfg.stable_max_cv_interval:
            windows_stable += 1
            stable_s += span
    night_s = float(max(end - start, 0))
    reasons: list[str] = ["unknown_time_never_stable"]
    if windows_evaluated == 0:
        status = "withheld"
        reasons.insert(0, "no_evaluable_windows")
    else:
        status = "available"
    have = windows_evaluated > 0
    return {
        "status": status,
        "reasons": reasons,
        "definition_version": STABLE_DEFINITION_VERSION,
        "criteria": {
            "window_s": float(rcfg.stable_window_s),
            "min_run_coverage": rcfg.stable_min_run_coverage,
            "min_intervals": float(rcfg.stable_min_intervals),
            "max_cv_interval": rcfg.stable_max_cv_interval,
        },
        "stable_minutes": json_finite(stable_s / 60.0) if have else None,
        "evaluated_minutes": json_finite(evaluated_s / 60.0),
        "unknown_minutes": json_finite((night_s - evaluated_s) / 60.0),
        "night_minutes": json_finite(night_s / 60.0),
        "windows_total": windows_total,
        "windows_evaluated": windows_evaluated,
        "windows_stable": windows_stable if have else None,
        "stable_fraction_of_evaluated": json_finite(stable_s / evaluated_s) if have else None,
        "stable_fraction_of_night": (json_finite(stable_s / night_s)
                                     if (have and night_s > 0) else None),
        "unit": "min",
    }


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

    # --- spec-02: true intervals (both peaks inside one run) -----------------
    true_ids = _true_run_ids(intervals, runs)
    true_usable_idx = [i for i in range(n) if usable_idx[i] and true_ids[i] >= 0]
    true_usable_ds = [intervals[i].seconds for i in true_usable_idx]

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
        # spec-02: the stage's TRUE intervals (gap-spanning pseudo-intervals excluded).
        stage_true_idx = [i for w in stage_windows for i in range(w["lo"], w["hi"])
                          if true_ids[i] >= 0]
        stage_true_ds = [intervals[i].seconds for i in stage_true_idx]
        entry["sd_interval_s"] = (json_finite(statistics.stdev(stage_true_ds))
                                  if len(stage_true_ds) >= 2 else None)
        entry["rmssd_interval_s"] = _rmssd_adjacent(stage_true_idx, intervals, true_ids)
        entry["median_interval_s"] = (json_finite(statistics.median(stage_true_ds))
                                      if stage_true_ds else None)
        entry["iqr_interval_s"] = _iqr(stage_true_ds)
        entry["true_intervals"] = len(stage_true_ds)
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
        # spec-02 (docs/spec-02/CONTRACT.md 5.2)
        "method_version": METHOD_VERSION,
        "config": RESP_CONFIG.to_wire(),
        "supported_range": dict(SUPPORTED_RANGE),
        "interval_distribution": _interval_distribution(true_usable_ds, len(usable), RESP_CONFIG),
        "stable_modulation": _stable_modulation(start, end, intervals, true_ids, runs, RESP_CONFIG),
    }
