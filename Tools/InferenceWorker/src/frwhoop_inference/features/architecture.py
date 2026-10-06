"""Sleep architecture dynamics (spec section 5 A2, contract \u00a73 architecture).

``compute_night`` returns the per-night ``architecture`` wire block.

Transition statistics are computed directly from the canonical timeline
(contract \u00a73, frozen): C_ij counts adjacent FULLY-OBSERVED known 30 s
epochs i->j including self transitions; pairs containing UNS are excluded;
pairs crossing an unresolved gap are excluded (``timeline.gap_epoch_span``).
YASA's own ``transition_matrix`` cannot express those exclusions (it counts
UNS pairs and knows nothing about real time gaps), so the block uses the
timeline, which is the same grid YASA receives.

* P_ij = C_ij / row sum; an unobserved row is a null row, not zeros.
* Row weights w_i = row transition count / total eligible transition count.
* Entropy rate H = -sum_i w_i * sum_j P_ij log2(P_ij) (zero terms skipped),
  units bits per 30-second transition; >= 100 eligible pairs required, else
  null + ``thin_data``.
* Bout statistics come from ``timeline.stage_intervals`` (count / median /
  p90 / max / total minutes) for each stage.
* REM/deep latency are measured from actual sleep onset s (NOT YASA's
  Lat_REM which is from recording start).
* Deep front-load fraction = deep seconds in the first third of [s,f) /
  total deep seconds; REM late fraction = REM seconds in the final third /
  total REM. Thirds split ELAPSED sleep-period time; unknown time stays in
  the axis and its known fraction is reported in
  ``sleep_period_third_known_fraction`` (spec A2: "its coverage is reported").

``occupancy_entropy_bits`` is a separate, differently-named statistic (stage
occupancy entropy over the label distribution); it is never emitted as the
transition entropy rate.
"""

from __future__ import annotations

import math
from typing import Any, Sequence

import numpy as np

from .config import SleepFeaturesConfig
from .contract import SleepFeaturesRequest, json_finite
from .timeline import Timeline, actual_sleep_onset, final_sleep_end

STAGE_ORDER = ("wake", "light", "deep", "rem")
SLEEP_STAGES = ("light", "deep", "rem")
_MINUTES = 60.0


def _transition_matrix(timeline: Timeline) -> tuple[list[list[int]], int, int, int]:
    """C_ij counts plus the exclusion tallies (eligible, UNS, gap)."""
    n = len(STAGE_ORDER)
    idx = {stage: i for i, stage in enumerate(STAGE_ORDER)}
    counts = [[0] * n for _ in range(n)]
    eligible = 0
    uns_excluded = 0
    gap_excluded = 0
    for i in range(timeline.n_epochs - 1):
        a, b = timeline.labels[i], timeline.labels[i + 1]
        # Classification order matters: a pair crossing an unresolved gap or
        # containing UNS is tallied in its own excluded bucket FIRST, even when
        # the epochs are not fully observed (gap epochs are UNS with no
        # coverage). A pair straddles a gap when EITHER epoch lies in the gap
        # (``gap_epoch_span`` reports the gap containing an epoch; the pair
        # (i, i+1) crosses the gap when epoch i or epoch i+1 is inside it).
        # Only known fully-observed pairs become eligible; a pair with a
        # partial (not fully-observed) known epoch is neither UNS nor a gap, so
        # it falls in no excluded counter (contract \u00a71).
        if (timeline.gap_epoch_span(i) is not None
                or timeline.gap_epoch_span(i + 1) is not None):
            gap_excluded += 1
            continue
        if a == "uns" or b == "uns":
            uns_excluded += 1
            continue
        if not (timeline.fully_observed[i] and timeline.fully_observed[i + 1]):
            continue
        counts[idx[a]][idx[b]] += 1
        eligible += 1
    return counts, eligible, uns_excluded, gap_excluded


def _entropy_rate(
    counts: list[list[int]], eligible: int, cfg: SleepFeaturesConfig
) -> tuple[float | None, str | None]:
    if eligible < cfg.entropy_min_pairs:
        return None, "thin_data"
    h = 0.0
    for row in counts:
        row_sum = sum(row)
        if row_sum <= 0:
            continue
        w = row_sum / float(eligible)
        row_h = 0.0
        for cell in row:
            if cell <= 0:
                continue
            p = cell / float(row_sum)
            row_h += p * math.log2(p)
        h += w * (-row_h)
    return float(h), None


def occupancy_entropy_bits(labels: Sequence[str]) -> float:
    """Stage-occupancy entropy over the label distribution.

    A DIFFERENT statistic from the transition entropy rate (spec A2). It is
    never emitted under the ``entropy_rate_bits_per_transition`` key. Used by
    tests to prove the two are distinct.
    """
    counts: dict[str, int] = {}
    for label in labels:
        counts[label] = counts.get(label, 0) + 1
    total = float(len(labels))
    if total <= 0:
        return 0.0
    h = 0.0
    for count in counts.values():
        p = count / total
        h -= p * math.log2(p)
    return float(h)


def _bout_stats(timeline: Timeline, stage: str) -> dict[str, Any]:
    intervals = timeline.stage_intervals(stage)
    durations_min = [(hi - lo) / _MINUTES for lo, hi in intervals]
    if not durations_min:
        return {
            "count": 0,
            "median_min": None,
            "p90_min": None,
            "max_min": None,
            "total_min": 0.0,
        }
    return {
        "count": len(durations_min),
        "median_min": json_finite(round(float(np.median(durations_min)), 2)),
        "p90_min": json_finite(round(float(np.percentile(durations_min, 90)), 2)),
        "max_min": json_finite(round(max(durations_min), 2)),
        "total_min": json_finite(round(sum(durations_min), 2)),
    }


def _first_start(timeline: Timeline, stage: str) -> int | None:
    intervals = timeline.stage_intervals(stage)
    return intervals[0][0] if intervals else None


def _third_coverage(timeline: Timeline, s: int, f: int) -> list[float]:
    """Known-label fraction of each elapsed-sleep-period third of [s, f)."""
    third = (f - s) / 3.0
    out: list[float] = []
    for k in range(3):
        lo = s + k * third
        hi = s + (k + 1) * third
        known = timeline.seconds_between(lo, hi, ("wake", "light", "deep", "rem"))
        out.append(json_finite(round(known / third, 4)) if third > 0 else None)
    return out


def compute_night(
    req: SleepFeaturesRequest,
    tl: Timeline,
    cfg: SleepFeaturesConfig,
) -> dict[str, Any]:
    """The per-night ``architecture`` block (contract \u00a73 architecture)."""
    del req  # pure function of the canonical timeline
    reasons: list[str] = []

    counts, eligible, uns_excluded, gap_excluded = _transition_matrix(tl)

    # Probabilities with null rows for unobserved rows.
    probabilities: list[list[float | None]] = []
    row_counts: list[int] = []
    for row in counts:
        row_sum = sum(row)
        row_counts.append(row_sum)
        if row_sum <= 0:
            probabilities.append([None] * len(STAGE_ORDER))
        else:
            probabilities.append([cell / float(row_sum) for cell in row])

    row_weights: list[float | None]
    if eligible > 0:
        row_weights = [row_sum / float(eligible) for row_sum in row_counts]
    else:
        row_weights = [None] * len(STAGE_ORDER)

    entropy, entropy_reason = _entropy_rate(counts, eligible, cfg)
    if entropy_reason:
        reasons.append(entropy_reason)

    bouts = {stage: _bout_stats(tl, stage) for stage in STAGE_ORDER}

    s = actual_sleep_onset(tl)
    f = final_sleep_end(tl)
    has_sleep = s is not None and f is not None

    rem_latency_from_onset_min: float | None = None
    deep_latency_from_onset_min: float | None = None
    first_rem = _first_start(tl, "rem")
    first_deep = _first_start(tl, "deep")
    if has_sleep and s is not None:
        if first_rem is not None:
            rem_latency_from_onset_min = (first_rem - s) / _MINUTES
        else:
            reasons.append("no_rem")
        if first_deep is not None:
            deep_latency_from_onset_min = (first_deep - s) / _MINUTES
        else:
            reasons.append("no_deep")
    else:
        reasons.append("no_sleep")

    deep_front_load_fraction: float | None = None
    rem_late_fraction: float | None = None
    sleep_period_third_known_fraction: list[float | None] | None = None
    if has_sleep and s is not None and f is not None:
        third = (f - s) / 3.0
        sleep_period_third_known_fraction = _third_coverage(tl, s, f)
        deep_front = tl.seconds_between(s, s + third, ("deep",))
        deep_total = tl.seconds_between(s, f, ("deep",))
        if deep_total > 0:
            deep_front_load_fraction = deep_front / deep_total
        else:
            deep_front_load_fraction = None
            if "no_deep" not in reasons:
                reasons.append("no_deep")
        rem_late = tl.seconds_between(f - third, f, ("rem",))
        rem_total = tl.seconds_between(s, f, ("rem",))
        if rem_total > 0:
            rem_late_fraction = rem_late / rem_total
        else:
            rem_late_fraction = None
            if "no_rem" not in reasons:
                reasons.append("no_rem")

    block = {
        "transition_counts": [[int(c) for c in row] for row in counts],
        "transition_probabilities": [
            [json_finite(v) if v is not None else None for v in row]
            for row in probabilities
        ],
        "row_weights": row_weights,
        "entropy_rate_bits_per_transition": json_finite(entropy),
        "bouts": bouts,
        "rem_latency_from_onset_min": json_finite(
            None if rem_latency_from_onset_min is None else round(rem_latency_from_onset_min, 2)),
        "deep_latency_from_onset_min": json_finite(
            None if deep_latency_from_onset_min is None else round(deep_latency_from_onset_min, 2)),
        "deep_front_load_fraction": json_finite(
            None if deep_front_load_fraction is None else round(deep_front_load_fraction, 4)),
        "rem_late_fraction": json_finite(
            None if rem_late_fraction is None else round(rem_late_fraction, 4)),
        "eligible_pairs": eligible,
        "excluded_pairs_uns": uns_excluded,
        "excluded_pairs_gap": gap_excluded,
        "sleep_period_third_known_fraction": sleep_period_third_known_fraction,
    }

    # Continuity summary gate (spec 4.2) applies to architecture as well.
    b = tl.night.start
    e = tl.night.end
    observed_onset_edge = bool(tl.labels and tl.labels[0] != "uns")
    observed_offset_edge = bool(tl.labels and tl.labels[-1] != "uns")
    internal_gap = any(g0 > b and g1 < e for g0, g1 in tl.unresolved_gaps)
    if tl.known_fraction < cfg.continuity_known_fraction:
        reasons.append("low_timeline_coverage")
    if not observed_onset_edge:
        reasons.append("unobserved_onset_edge")
    if not observed_offset_edge:
        reasons.append("unobserved_offset_edge")
    if internal_gap:
        reasons.append("unresolved_internal_gap")

    block["status"] = "partial" if reasons else "available"
    block["reasons"] = sorted(set(reasons))
    return block
