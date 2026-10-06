"""Sleep regularity (spec A3): rolling SRI + circular timing variability.

Owner: worker-regularity. Locked by docs/SLEEP_FEATURES_CONTRACT.md section 3
(the ``regularity`` block) and spec-25.md section A3.

Public entry point (frozen signature):

    compute(req: SleepFeaturesRequest, cfg: SleepFeaturesConfig) -> dict

returns the whole-document ``regularity`` wire block.  No new composite score,
no clinical claims; every metric is a JSON-finite leaf or null with a
machine-readable reason.
"""

from __future__ import annotations

import math
from datetime import datetime
from typing import Any, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .config import SleepFeaturesConfig
from .contract import MIN_VALID_DAY_MINUTES, SleepFeaturesRequest, json_finite
from .timeline import actual_sleep_onset, build_timeline, final_sleep_end

#: Elapsed-time SRI lag (spec A3): exactly 24 h, in UTC minutes.
SRI_LAG_MINUTES = 24 * 60
#: Circular period for clock metrics (one day), in local minutes.
DAY_PERIOD_MIN = 1440.0
#: Local hours treated as "daytime" for the valid-daytime-decision gate.  The
#: upstream worker marks a minute ``valid`` only when it is monitored and
#: classified; if no valid minute ever falls in these local hours, the
#: repository could not establish a daytime decision and SRI is withheld.
DAYTIME_LOCAL_HOURS = range(9, 21)
#: Window sizes for rolling SRI, in days.
SRI_WINDOWS = (7, 14, 30)

AVAILABLE = "available"
PARTIAL = "partial"
WITHHELD = "withheld"


# ---------------------------------------------------------------------------
# History grid (1-minute UTC)
# ---------------------------------------------------------------------------


def _build_history_grid(history_days):
    """Collapse ``history.days`` to the canonical 1-minute UTC grid.

    Returns ``(grid, ts_to_day, day_valid, bad_spacing_days)`` where
    ``grid[ts] == (state, valid)``, ``ts_to_day`` maps each minute's start to
    its history day label, ``day_valid`` maps a day label to its valid-minute
    count (0 for days dropped for irregular spacing) and ``bad_spacing_days``
    lists days whose minutes are not spaced at regular 60 s.
    """
    grid: dict[int, tuple[int, bool]] = {}
    ts_to_day: dict[int, str] = {}
    day_valid: dict[str, int] = {}
    bad_spacing: list[str] = []
    for day in history_days:
        ts_list = [m.ts for m in day.minutes]
        spacing_ok = all(b - a == 60 for a, b in zip(ts_list, ts_list[1:]))
        if not spacing_ok:
            # A day whose grid is not a true 1-minute grid cannot be trusted
            # for elapsed pairing; treat it as missing for SRI purposes.
            day_valid[day.day] = 0
            bad_spacing.append(day.day)
            continue
        day_valid[day.day] = sum(1 for m in day.minutes if m.valid)
        for m in day.minutes:
            # First writer wins if two days ever share a minute (should not
            # happen; the builder partitions UTC time per local day).
            grid.setdefault(m.ts, (m.state, m.valid))
            ts_to_day.setdefault(m.ts, day.day)
    return grid, ts_to_day, day_valid, bad_spacing


def _window_days(history_days, size: int) -> list[str]:
    """The most recent ``size`` history day labels (chronological, last first).

    The window is over the days the request actually carries; fewer than
    ``size`` provided days simply means a smaller window.
    """
    labels = sorted({d.day for d in history_days})
    return labels[-size:]


def _local_hour(ts: int, tz: ZoneInfo) -> int:
    return datetime.fromtimestamp(ts, tz=tz).hour


def _sri_window(grid, ts_to_day, day_valid, window_labels, cfg, tz):
    """One rolling SRI window: eligible/paired minutes, value and gates.

    A minute pair ``(t, t + 1440 min)`` is eligible when both minutes exist on
    the grid, both belong to days inside the window, and neither day is
    "missing" (fewer than 12 h valid minutes - a pair spanning a missing
    intervening day is excluded).  It is paired only when both minutes are
    valid (monitored and classified).  ``tz`` is used only for the
    valid-daytime-decision gate (local hours); pairing itself stays on the
    elapsed UTC grid and is therefore DST-immune.
    """
    window = set(window_labels)
    eligible = 0
    paired = 0
    agree = 0
    daytime_paired = 0

    for t in sorted(grid):
        t2 = t + SRI_LAG_MINUTES * 60
        if t2 not in grid:
            continue
        d1 = ts_to_day.get(t)
        d2 = ts_to_day.get(t2)
        if d1 is None or d2 is None or d1 not in window or d2 not in window:
            continue
        if day_valid.get(d1, 0) < MIN_VALID_DAY_MINUTES or day_valid.get(d2, 0) < MIN_VALID_DAY_MINUTES:
            continue
        eligible += 1
        s1, v1 = grid[t]
        s2, v2 = grid[t2]
        if v1 and v2:
            paired += 1
            if s1 == s2:
                agree += 1
            if tz is not None and _local_hour(t, tz) in DAYTIME_LOCAL_HOURS:
                daytime_paired += 1

    valid_days = sum(
        1 for lb in window_labels if day_valid.get(lb, 0) >= MIN_VALID_DAY_MINUTES
    )

    reasons: list[str] = []
    if valid_days < cfg.sri_min_valid_days:
        reasons += ["insufficient_history", "insufficient_valid_days"]
    if paired < cfg.sri_min_paired_minutes:
        reasons += ["insufficient_history", "insufficient_paired_minutes"]
    pair_fraction = (paired / eligible) if eligible else 0.0
    if eligible == 0 or pair_fraction < cfg.sri_min_pair_fraction:
        reasons += ["insufficient_history", "insufficient_pair_fraction"]
    if eligible > 0 and paired > 0 and daytime_paired == 0:
        reasons.append("no_valid_daytime_decision")

    if reasons:
        return {
            "value": None,
            "paired_minutes": paired,
            "eligible_minutes": eligible,
            "valid_days": valid_days,
            "status": WITHHELD,
            "reasons": list(dict.fromkeys(reasons)),
        }
    value = 200.0 * (agree / paired) - 100.0
    return {
        "value": json_finite(value),
        "paired_minutes": paired,
        "eligible_minutes": eligible,
        "valid_days": valid_days,
        "status": AVAILABLE,
        "reasons": [],
    }


def _pair_coverage_by_hour(grid, ts_to_day, day_valid) -> list[int]:
    """Paired minutes by UTC hour of the EARLIER minute, over all history.

    Uses the same eligibility rule as the rolling windows (both minutes valid,
    no missing intervening day).  This is the "profile by clock time".
    """
    by_hour = [0] * 24
    for t in sorted(grid):
        t2 = t + SRI_LAG_MINUTES * 60
        if t2 not in grid:
            continue
        d1 = ts_to_day.get(t)
        d2 = ts_to_day.get(t2)
        if d1 is None or d2 is None:
            continue
        if day_valid.get(d1, 0) < MIN_VALID_DAY_MINUTES or day_valid.get(d2, 0) < MIN_VALID_DAY_MINUTES:
            continue
        s1, v1 = grid[t]
        s2, v2 = grid[t2]
        if v1 and v2:
            by_hour[(t // 3600) % 24] += 1
    return by_hour


# ---------------------------------------------------------------------------
# Circular clock metrics (local clock minutes -> angles)
# ---------------------------------------------------------------------------


def _local_minute(ts: int, tz: ZoneInfo) -> float:
    dt = datetime.fromtimestamp(ts, tz=tz)
    return float(dt.hour * 60 + dt.minute)


def _circular_mean_sd_minutes(minutes: Sequence[float]) -> tuple[float | None, float | None, int]:
    """Circular mean and circular SD (minutes) of local clock minutes."""
    n = len(minutes)
    if n == 0:
        return None, None, 0
    theta = [2.0 * math.pi * m / DAY_PERIOD_MIN for m in minutes]
    sx = sum(math.sin(a) for a in theta)
    cy = sum(math.cos(a) for a in theta)
    r = min(1.0, math.hypot(sx, cy) / n)
    mean_theta = math.atan2(sx, cy) % (2.0 * math.pi)
    mean_min = mean_theta * DAY_PERIOD_MIN / (2.0 * math.pi)
    if r <= 0.0:
        return mean_min, None, n
    sd_rad = math.sqrt(-2.0 * math.log(r))
    return mean_min, sd_rad * DAY_PERIOD_MIN / (2.0 * math.pi), n


def _shortest_circular_diff_min(m1: float, m2: float) -> float:
    """Signed shortest circular difference m2 - m1, in minutes, within (-720, 720]."""
    d = (m2 - m1) % DAY_PERIOD_MIN
    if d > DAY_PERIOD_MIN / 2.0:
        d -= DAY_PERIOD_MIN
    return d


def _median(values: Sequence[float]) -> float:
    ordered = sorted(values)
    n = len(ordered)
    if n % 2 == 1:
        return ordered[n // 2]
    return (ordered[n // 2 - 1] + ordered[n // 2]) / 2.0


def _circular_metric(minutes: Sequence[float]) -> dict[str, Any]:
    mean_min, sd_min, n = _circular_mean_sd_minutes(minutes)
    if n == 0:
        return {
            "circadian_mean_min": None,
            "circadian_sd_min": None,
            "n": 0,
            "status": WITHHELD,
            "reasons": ["insufficient_nights"],
        }
    # A circular SD needs >= 2 observations: with n == 1 the wrapped
    # resultant is 1 and the SD formula yields a fake 0 (audit P2-4). The
    # mean may still publish; the SD is withheld, honestly.
    if n < 2:
        return {
            "circadian_mean_min": json_finite(mean_min),
            "circadian_sd_min": None,
            "n": n,
            "status": PARTIAL,
            "reasons": ["insufficient_nights_for_sd"],
        }
    return {
        "circadian_mean_min": json_finite(mean_min),
        "circadian_sd_min": json_finite(sd_min),
        "n": n,
        "status": AVAILABLE,
        "reasons": [],
    }


def _history_night_minutes(history_days, tz) -> list[dict[str, Any]]:
    """Per-night timing from the history grid (minute resolution).

    For each history day: monitored minutes group into contiguous spans; the
    span holding the day's LONGEST sleep run is the night (naps excluded the
    same way the request's is_nap rule excludes them). bed = span start,
    onset = first sleep minute, wake = last sleep minute end, midsleep =
    midpoint. Days with no sleep run are skipped.
    """
    out: list[dict[str, Any]] = []
    for day in history_days:
        valid = [m for m in day.minutes if m.valid]
        if not valid:
            continue
        # contiguous monitored spans (60 s spacing)
        spans: list[list[Any]] = []
        for m in valid:
            if spans and m.ts == spans[-1][-1].ts + 60:
                spans[-1].append(m)
            else:
                spans.append([m])
        # longest sleep run per span
        best: tuple[int, list[Any]] | None = None  # (sleep_run_minutes, span)
        for span in spans:
            run = 0
            best_run = 0
            for m in span:
                run = run + 1 if m.state == 1 else 0
                best_run = max(best_run, run)
            if best_run > 0 and (best is None or best_run > best[0]):
                best = (best_run, span)
        if best is None:
            continue
        span = best[1]
        sleep_ts = [m.ts for m in span if m.state == 1]
        if not sleep_ts:
            continue
        onset_ts = min(sleep_ts)
        wake_ts = max(sleep_ts) + 60
        bed_ts = span[0].ts
        out.append({
            "night": bed_ts,
            "bed": _local_minute(bed_ts, tz),
            "onset": _local_minute(onset_ts, tz),
            "wake": _local_minute(wake_ts, tz),
            "midsleep": _local_minute((onset_ts + wake_ts) // 2, tz),
            "offset": datetime.fromtimestamp(bed_ts, tz=tz).utcoffset(),
        })
    return sorted(out, key=lambda d: d["night"])


def _clock_profile(req: SleepFeaturesRequest) -> dict[str, Any]:
    """Timing variability from the request's main nights (DST-aware, local)."""
    try:
        tz = ZoneInfo(req.context.iana_timezone)
    except ZoneInfoNotFoundError:
        return {
            "bed_time": {"circadian_mean_min": None, "circadian_sd_min": None,
                         "n": 0, "status": WITHHELD, "reasons": ["invalid_timezone"]},
            "sleep_onset": {"circadian_mean_min": None, "circadian_sd_min": None,
                            "n": 0, "status": WITHHELD, "reasons": ["invalid_timezone"]},
            "final_wake": {"circadian_mean_min": None, "circadian_sd_min": None,
                           "n": 0, "status": WITHHELD, "reasons": ["invalid_timezone"]},
            "midsleep": {"circadian_mean_min": None, "circadian_sd_min": None,
                         "n": 0, "status": WITHHELD, "reasons": ["invalid_timezone"]},
            "adjacent_night_phase_shift_min": {"value": None, "n": 0, "status": WITHHELD,
                                               "reasons": ["invalid_timezone"]},
            "social_jetlag_min": {"value": None, "status": WITHHELD,
                                  "reasons": ["workday_labels_unavailable"]},
            "dst_transition_days": 0,
        }

    # Timing metrics describe the night-time schedule: use MAIN nights only.
    # A nap's "night start" is not a bed time and would corrupt the schedule
    # metrics.  (Naps still count as sleep inside the SRI history grid.)
    nights = sorted((n for n in req.nights if not n.is_nap), key=lambda n: n.start)

    bed: list[float] = []
    onset: list[float] = []
    final_wake: list[float] = []
    midsleep: list[float] = []
    midsleep_by_night: list[tuple[int, float]] = []
    offsets: list[Any] = []

    for night in nights:
        tl = build_timeline(night)
        bed.append(_local_minute(night.start, tz))
        offsets.append(datetime.fromtimestamp(night.start, tz=tz).utcoffset())
        s = actual_sleep_onset(tl)
        f = final_sleep_end(tl)
        if s is not None:
            onset.append(_local_minute(s, tz))
        if f is not None:
            final_wake.append(_local_minute(f, tz))
        if s is not None and f is not None:
            mid = _local_minute((s + f) // 2, tz)
            midsleep.append(mid)
            midsleep_by_night.append((night.start, mid))

    dst_transition_days = sum(1 for a, b in zip(offsets, offsets[1:]) if a != b)

    timing_source = "request_nights"
    if len(midsleep_by_night) < 2:
        # The request carries only the current day's nights (one main night in
        # production), so schedule variability over ONE night is degenerate
        # (audit P1-3). The 31-day history grid the worker already sends
        # carries the multi-night schedule: derive per-night timing from its
        # monitored spans (bed = span start of the span holding the day's
        # longest sleep run; onset/wake = first/last sleep minute; midsleep =
        # their midpoint). Minute-resolution, staged-grid-derived — labeled so
        # the consumer cannot mistake it for exact staged boundaries.
        derived = _history_night_minutes(req.history_days, tz)
        if len(derived) >= 2:
            timing_source = "history_grid"
            bed = [d["bed"] for d in derived]
            onset = [d["onset"] for d in derived]
            final_wake = [d["wake"] for d in derived]
            midsleep = [d["midsleep"] for d in derived]
            midsleep_by_night = [(d["night"], d["midsleep"]) for d in derived]
            offsets = [d["offset"] for d in derived]
            dst_transition_days = sum(1 for a, b in zip(offsets, offsets[1:]) if a != b)

    diffs = [
        _shortest_circular_diff_min(m1, m2)
        for (_, m1), (_, m2) in zip(midsleep_by_night, midsleep_by_night[1:])
    ]
    if diffs:
        phase_shift = {
            "value": json_finite(_median(diffs)),
            "n": len(diffs),
            "status": AVAILABLE,
            "reasons": [],
        }
    else:
        phase_shift = {"value": None, "n": 0, "status": WITHHELD,
                       "reasons": ["insufficient_nights"]}

    return {
        "timing_source": timing_source,
        "bed_time": _circular_metric(bed),
        "sleep_onset": _circular_metric(onset),
        "final_wake": _circular_metric(final_wake),
        "midsleep": _circular_metric(midsleep),
        "adjacent_night_phase_shift_min": phase_shift,
        "social_jetlag_min": {"value": None, "status": WITHHELD,
                              "reasons": ["workday_labels_unavailable"]},
        "dst_transition_days": dst_transition_days,
    }


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def compute(req: SleepFeaturesRequest, cfg: SleepFeaturesConfig) -> dict:
    """Whole-document ``regularity`` wire block (spec A3, contract section 3)."""
    grid, ts_to_day, day_valid, bad_spacing = _build_history_grid(req.history_days)
    has_history = len(req.history_days) > 0

    tz: ZoneInfo | None = None
    try:
        tz = ZoneInfo(req.context.iana_timezone)
    except ZoneInfoNotFoundError:
        tz = None  # SRI is grid-based; only the daytime gate needs tz

    windows: dict[str, dict[str, Any]] = {}
    for size in SRI_WINDOWS:
        key = f"sri_{size}d"
        if not has_history:
            windows[key] = {
                "value": None, "paired_minutes": 0, "eligible_minutes": 0,
                "valid_days": 0, "status": WITHHELD, "reasons": ["no_history"],
            }
        else:
            labels = _window_days(req.history_days, size)
            windows[key] = _sri_window(grid, ts_to_day, day_valid, labels, cfg, tz)

    pair_hour = (
        _pair_coverage_by_hour(grid, ts_to_day, day_valid) if has_history else [0] * 24
    )
    clock = _clock_profile(req)

    clock_metrics = (clock["bed_time"], clock["sleep_onset"], clock["final_wake"],
                     clock["midsleep"], clock["adjacent_night_phase_shift_min"])
    # A PARTIAL clock metric still delivers values (e.g. an n=1 mean with the
    # SD withheld), so it counts as delivered timing for the block status.
    timing_available = any(m["status"] in (AVAILABLE, PARTIAL) for m in clock_metrics)
    # ``social_jetlag_min`` is a known first-wave capability gap
    # (workday_labels_unavailable); like the capabilities gate it does not
    # degrade the block status or block reasons.  The four schedule metrics
    # and the adjacent-night phase shift do.
    all_clock_available = all(m["status"] == AVAILABLE for m in clock_metrics)

    window_statuses = [windows[f"sri_{size}d"]["status"] for size in SRI_WINDOWS]
    if all(s == AVAILABLE for s in window_statuses) and all_clock_available:
        status = AVAILABLE
    elif timing_available or any(s == AVAILABLE for s in window_statuses):
        status = PARTIAL
    else:
        status = WITHHELD

    reasons: list[str] = []
    for size in SRI_WINDOWS:
        reasons.extend(windows[f"sri_{size}d"]["reasons"])
    for metric in clock_metrics:
        reasons.extend(metric["reasons"])
    if bad_spacing:
        reasons.append("irregular_history_spacing")
    reasons = list(dict.fromkeys(reasons))

    return {
        "pair_policy": "elapsed_24h",
        "sri_7d": windows["sri_7d"],
        "sri_14d": windows["sri_14d"],
        "sri_30d": windows["sri_30d"],
        "pair_coverage_by_hour": pair_hour,
        "clock_profile": clock,
        "status": status,
        "reasons": reasons,
        "history_revision_digest": req.context.history_revision_digest,
    }
