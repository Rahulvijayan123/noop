"""Sleep continuity and fragmentation (spec section 5 A1, contract \u00a73 continuity).

``compute_night`` returns the per-night ``continuity`` wire block. All duration
metrics use the canonical timeline's exact segment intersections; run-based
statistics (SOL_5min, sleep bouts, recurrent awakenings) use the fully-observed
aligned 30 s epochs, exactly like the contract's transition-statistics rule, so
a partial first/last epoch keeps its true duration in the public minute metrics
and never pads a run with assumed sleep.

Definitions (spec A1, authoritative):
* b/e = the canonical night's [start, end); s = actual sleep onset (first sleep
  epoch start), f = final sleep end (end of last sleep epoch) from
  features/timeline.py.
* TIB = e-b; TST = exact sum of LIGHT/DEEP/REM; SOL = s-b; SOL_5min = onset of
  the first uninterrupted sleep run >= 300 s minus b; SPT = f-s.
* WASO = known WAKE within [s,f); terminal wake = known WAKE within [f,e).
* Sleep efficiency = TST/TIB (pct); sleep-maintenance efficiency = TST/SPT (pct).
* A recurrent awakening is an internal WAKE run bounded by known sleep on both
  sides (terminal and initial wake are excluded). Recurrent-awakening index =
  internal count / (TST/3600). Return-to-sleep latency = that internal run's
  duration.
* Sleep bouts merge LIGHT/DEEP/REM into one sleep label before run extraction.
* ``sfi_yasa_per_h`` is YASA 0.8.0's SFI (sleep->WAKE transitions incl. the
  terminal awakening per hour of TST). It is deliberately NOT the recurrent
  awakening index and the two are never equated.

Continuity summary gate (spec 4.2): >= 95% known timeline coverage, observed
onset/offset edges, and no unresolved INTERNAL gap over 60 s. When the gate
fails the block publishes as ``partial`` with machine-readable reasons; every
supported quantity is still published.

No sleep -> null onset/latency metrics (SOL, SOL_5min, SPT, WASO, terminal
wake, SME, recurrent index) with reason ``no_sleep``. A complete trace with no
internal wake event reports a valid 0 event count.
"""

from __future__ import annotations

import math
import statistics
from datetime import datetime, timezone
from typing import Any, Sequence

import numpy as np

from .config import SleepFeaturesConfig
from .contract import SleepFeaturesRequest, json_finite
from .timeline import Timeline, actual_sleep_onset, final_sleep_end, yasa_labels

SLEEP_STAGES = ("light", "deep", "rem")
STAGE_ORDER = ("wake", "light", "deep", "rem")

#: Internal WAKE runs at least this long (seconds) count in the 60 s bucket.
AWAKENING_60S = 60.0
#: A merged-sleep run must reach this duration to qualify as "persistent sleep"
#: for SOL_5min (spec A1: "at least 300 seconds").
PERSISTENT_SLEEP_S = 300.0

_MINUTES = 60.0


def _yasa_module():
    """Import yasa lazily so importing this module never depends on it."""
    import yasa  # noqa: PLC0415

    return yasa


def _yasa_stats(timeline: Timeline) -> tuple[dict[str, Any], int]:
    """``yasa.Hypnogram.sleep_statistics()`` rendered JSON-finite.

    Returns ``(stats, n_nonfinite)`` where every numeric leaf of ``stats`` is a
    plain float or None (NaN/inf are rendered as None so the wire block is
    always valid JSON; the keys are kept verbatim).
    """
    yasa = _yasa_module()
    hyp = yasa.Hypnogram(
        yasa_labels(timeline),
        n_stages=4,
        freq="30s",
        start=datetime.fromtimestamp(timeline.night.start, tz=timezone.utc),
    )
    raw = hyp.sleep_statistics()
    out: dict[str, Any] = {}
    n_nonfinite = 0
    for key, value in raw.items():
        try:
            number = float(value)
        except (TypeError, ValueError):
            out[key] = value
            continue
        if math.isfinite(number):
            out[key] = number
        else:
            out[key] = None
            n_nonfinite += 1
    return out, n_nonfinite


def _known_sleep_runs(timeline: Timeline) -> list[tuple[int, int]]:
    """Maximal runs of contiguous fully-observed sleep epochs.

    Returns half-open ``(epoch_start, epoch_end)`` spans. UNS and wake epochs
    break a run; partial (not fully-observed) epochs never enter a run.
    """
    runs: list[tuple[int, int]] = []
    i = 0
    n = timeline.n_epochs
    while i < n:
        if timeline.labels[i] in SLEEP_STAGES and timeline.fully_observed[i]:
            j = i
            while j < n and timeline.labels[j] in SLEEP_STAGES and timeline.fully_observed[j]:
                j += 1
            runs.append((timeline.epoch_start(i), timeline.epoch_start(j)))
            i = j
        else:
            i += 1
    return runs


def _internal_wake_runs(timeline: Timeline) -> list[tuple[int, int]]:
    """WAKE runs bounded by known sleep on both sides (spec A1)."""
    out: list[tuple[int, int]] = []
    n = timeline.n_epochs
    for lo, hi in timeline.stage_intervals("wake"):
        i = (lo - timeline.night.start) // 30
        j = (hi - timeline.night.start) // 30
        if i - 1 < 0 or j >= n:
            continue  # touches the night boundary -> not internal
        if timeline.labels[i - 1] in SLEEP_STAGES and timeline.labels[j] in SLEEP_STAGES:
            out.append((lo, hi))
    return out


def _median(values: Sequence[float]) -> float | None:
    if not values:
        return None
    return float(statistics.median(values))


def _p90(values: Sequence[float]) -> float | None:
    if not values:
        return None
    return float(np.percentile(values, 90))


def _duration_minutes(start: int, end: int) -> float:
    return (end - start) / _MINUTES


def compute_night(
    req: SleepFeaturesRequest,
    tl: Timeline,
    cfg: SleepFeaturesConfig,
) -> dict[str, Any]:
    """The per-night ``continuity`` block (contract \u00a73 continuity).

    Pure and deterministic. ``req`` is accepted for signature stability with the
    other night modules; all inputs come from the canonical ``tl``.
    """
    del req  # continuity is a pure function of the canonical timeline
    reasons: list[str] = []
    b = tl.night.start
    e = tl.night.end

    tib_min = _duration_minutes(b, e)
    tst_min = sum(tl.stage_seconds.get(st, 0.0) for st in SLEEP_STAGES) / _MINUTES

    s = actual_sleep_onset(tl)
    f = final_sleep_end(tl)

    has_sleep = bool(s is not None and f is not None and tst_min > 0)

    # --- onset / latency -----------------------------------------------------
    sol_min: float | None = None
    sol_5min_run_min: float | None = None
    spt_min: float | None = None
    if has_sleep and s is not None:
        sol_min = _duration_minutes(b, s)
        # First uninterrupted sleep run >= 300 s (fully-observed epochs).
        for run_lo, run_hi in _known_sleep_runs(tl):
            if run_hi - run_lo >= PERSISTENT_SLEEP_S:
                sol_5min_run_min = _duration_minutes(b, run_lo)
                break
        if sol_5min_run_min is None:
            # Sleep exists but no uninterrupted >= 300 s run (e.g. a short
            # nap): the latency is genuinely not computable.
            reasons.append("no_persistent_sleep_run")
    else:
        reasons.append("no_sleep")

    if has_sleep and s is not None and f is not None:
        spt_min = _duration_minutes(s, f)

    # --- wake quantities -----------------------------------------------------
    waso_min: float | None = None
    terminal_wake_min: float | None = None
    if has_sleep and s is not None and f is not None:
        waso_min = tl.seconds_between(s, f, ("wake",)) / _MINUTES
    if has_sleep and f is not None:
        terminal_wake_min = tl.seconds_between(f, e, ("wake",)) / _MINUTES
    else:
        terminal_wake_min = None

    sleep_efficiency_pct = 100.0 * tst_min / tib_min if tib_min > 0 else None
    sleep_maintenance_efficiency_pct: float | None = None
    if has_sleep and spt_min is not None and spt_min > 0:
        sleep_maintenance_efficiency_pct = 100.0 * tst_min / spt_min

    # --- recurrent awakenings ------------------------------------------------
    internal = _internal_wake_runs(tl)
    internal_60 = [run for run in internal if run[1] - run[0] >= AWAKENING_60S]
    recurrent_awakenings = len(internal)
    recurrent_awakenings_60s_plus = len(internal_60)
    recurrent_awakening_index_per_h: float | None = None
    if tst_min > 0:
        recurrent_awakening_index_per_h = recurrent_awakenings / (tst_min / 60.0)

    return_to_sleep_latency_median_min: float | None = None
    awakening_durations_min = [_duration_minutes(lo, hi) for lo, hi in internal]
    if awakening_durations_min:
        return_to_sleep_latency_median_min = _median(awakening_durations_min)
    awakening_duration = {
        "count": recurrent_awakenings,
        "median_min": json_finite(_median(awakening_durations_min)),
        "p90_min": json_finite(_p90(awakening_durations_min)),
        "max_min": json_finite(max(awakening_durations_min) if awakening_durations_min else None),
    }

    # --- sleep bouts (merged sleep label) ------------------------------------
    sleep_runs = _known_sleep_runs(tl)
    sleep_bout_durations_min = [_duration_minutes(lo, hi) for lo, hi in sleep_runs]
    longest_sleep_bout_min: float | None = None
    mean_sleep_bout_min: float | None = None
    if sleep_bout_durations_min:
        longest_sleep_bout_min = max(sleep_bout_durations_min)
        mean_sleep_bout_min = sum(sleep_bout_durations_min) / len(sleep_bout_durations_min)

    # --- YASA statistics (verbatim keys, JSON-finite leaves) -----------------
    # NaN/inf leaves (e.g. Lat_REM on a no-REM night, SFI on a no-sleep night)
    # are rendered as null; that is a rendering detail of a raw diagnostic
    # blob, not a missing sub-metric, so it never downgrades the block status.
    yasa_stats, n_nonfinite = _yasa_stats(tl)
    sfi_yasa_per_h = json_finite(yasa_stats.get("SFI"))
    del n_nonfinite

    # --- continuity summary gate (spec 4.2) ----------------------------------
    observed_onset_edge = bool(tl.labels and tl.labels[0] != "uns")
    observed_offset_edge = bool(tl.labels and tl.labels[-1] != "uns")
    internal_gap = any(g0 > b and g1 < e for g0, g1 in tl.unresolved_gaps)
    gate_ok = True
    if tl.known_fraction < cfg.continuity_known_fraction:
        gate_ok = False
        reasons.append("low_timeline_coverage")
    if not observed_onset_edge:
        gate_ok = False
        reasons.append("unobserved_onset_edge")
    if not observed_offset_edge:
        gate_ok = False
        reasons.append("unobserved_offset_edge")
    if internal_gap:
        gate_ok = False
        reasons.append("unresolved_internal_gap")

    block = {
        "tib_min": json_finite(round(tib_min, 2)),
        "tst_min": json_finite(round(tst_min, 2)),
        "sol_min": json_finite(None if sol_min is None else round(sol_min, 2)),
        "sol_5min_run_min": json_finite(None if sol_5min_run_min is None else round(sol_5min_run_min, 2)),
        "spt_min": json_finite(None if spt_min is None else round(spt_min, 2)),
        "waso_min": json_finite(None if waso_min is None else round(waso_min, 2)),
        "terminal_wake_min": json_finite(None if terminal_wake_min is None else round(terminal_wake_min, 2)),
        "sleep_efficiency_pct": json_finite(None if sleep_efficiency_pct is None else round(sleep_efficiency_pct, 2)),
        "sleep_maintenance_efficiency_pct": json_finite(
            None if sleep_maintenance_efficiency_pct is None else round(sleep_maintenance_efficiency_pct, 2)),
        "recurrent_awakenings": recurrent_awakenings,
        "recurrent_awakenings_60s_plus": recurrent_awakenings_60s_plus,
        "recurrent_awakening_index_per_h": json_finite(
            None if recurrent_awakening_index_per_h is None else round(recurrent_awakening_index_per_h, 3)),
        "return_to_sleep_latency_median_min": json_finite(
            None if return_to_sleep_latency_median_min is None else round(return_to_sleep_latency_median_min, 2)),
        "awakening_duration": awakening_duration,
        "longest_sleep_bout_min": json_finite(
            None if longest_sleep_bout_min is None else round(longest_sleep_bout_min, 2)),
        "mean_sleep_bout_min": json_finite(
            None if mean_sleep_bout_min is None else round(mean_sleep_bout_min, 2)),
        "sleep_bouts": {"count": len(sleep_bout_durations_min)},
        "sfi_yasa_per_h": json_finite(None if sfi_yasa_per_h is None else round(float(sfi_yasa_per_h), 2)),
        "yasa_stats": yasa_stats,
    }

    status = "available" if gate_ok and not reasons else "partial"
    block["status"] = status
    block["reasons"] = sorted(set(reasons))
    return block
