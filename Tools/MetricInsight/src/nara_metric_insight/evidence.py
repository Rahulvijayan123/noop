"""Deterministic evidence. Every number an explanation may state is computed here, never by the model.

Pure functions over the sources loaded for one job (sources.py). Conventions:
* A night without a plausible measurement is `None` — missing, never zero, never interpolated.
* Values are display values (metrics.Signal.scale) rounded to the signal's display precision; statistics are
  computed on unrounded values and rounded once at the end.
* The context layer's own judgments (reference comparisons and change episodes, chosen with the app's rules:
  MeasurementContextSelection.headlineReference / .episode) come first. When the context layer has no usable
  reference yet (a new account), a personal-range fallback over the measured nights is used and labelled as such.
"""

from __future__ import annotations

import math
from datetime import date, datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal
from statistics import median
from typing import Any
from zoneinfo import ZoneInfo

from .metrics import (BASELINE_NIGHTS, EPISODE_RANK, INSIGHT_METRICS, REFERENCE_ORDER, SIGNALS, WINDOW_DAYS,
                      InsightMetric, Signal, plausible)

RECENT_NIGHTS = 7             # the "last 7 nights" window


def _day(value: Any) -> date:
    return value if isinstance(value, date) else date.fromisoformat(str(value))


def rounded(value: float | None, decimals: int) -> float | int | None:
    """Display rounding, half up (50.5 -> 51, the way a person rounds)."""
    if value is None or not math.isfinite(value):
        return None
    quantum = Decimal(1).scaleb(-max(decimals, 0))
    result = Decimal(repr(float(value))).quantize(quantum, rounding=ROUND_HALF_UP)
    return int(result) if decimals <= 0 else float(result)


def shown_difference(a: float, b: float, decimals: int) -> float | int | None:
    """a - b as the reader would compute it from the two displayed values, so shown numbers always add up."""
    return rounded(float(rounded(a, decimals)) - float(rounded(b, decimals)), decimals)


def quantile(values: list[float], q: float) -> float:
    """Linear-interpolation quantile (the usual "type 7")."""
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * q
    low = math.floor(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def robust(values: list[float]) -> dict[str, float] | None:
    if not values:
        return None
    center = median(values)
    return {"n": len(values), "median": center, "p25": quantile(values, 0.25), "p75": quantile(values, 0.75),
            "mad": median([abs(v - center) for v in values])}


def nights(scores: dict[date, dict[str, Any]], signal: Signal, start: date, end: date) -> list[tuple[date, float | None]]:
    """Every calendar night from start to end with the signal's display value, None where not measured."""
    out: list[tuple[date, float | None]] = []
    day = start
    while day <= end:
        row = scores.get(day)
        out.append((day, plausible(signal, row.get(signal.column)) if row else None))
        day += timedelta(days=1)
    return out


def _direction(delta: float | None, flat: float) -> str:
    if delta is None:
        return "unknown"
    if abs(delta) < flat:
        return "flat"
    return "up" if delta > 0 else "down"


def _longest_gap(series: list[tuple[date, float | None]]) -> int:
    longest = current = 0
    for _, value in series:
        current = current + 1 if value is None else 0
        longest = max(longest, current)
    return longest


# --------------------------------------------------------------------------- context layer (app rules)


def _belongs(series_key: str, metric: InsightMetric) -> bool:
    return any(series_key.startswith(prefix) for prefix in metric.series_prefixes)


def headline_reference(comparisons: list[dict[str, Any]]) -> dict[str, Any] | None:
    """MeasurementContextSelection.headlineReference: a ready comparison with a difference first (rolling,
    recent, frozen, conditioned), then any with a difference, then the first one."""
    order = {view: i for i, view in enumerate(REFERENCE_ORDER)}
    ranked = sorted(comparisons, key=lambda c: order.get(c.get("view"), len(order)))
    return (next((c for c in ranked if c.get("status") == "ready" and c.get("signed_difference") is not None), None)
            or next((c for c in ranked if c.get("signed_difference") is not None), None)
            or (ranked[0] if ranked else None))


def headline_episode(reference: dict[str, Any] | None, episodes: list[dict[str, Any]],
                     metric: InsightMetric) -> dict[str, Any] | None:
    """MeasurementContextSelection.episode: the reference's series (same regime first), the most notable state
    first, the newest among equals."""
    if reference:
        exact = [e for e in episodes if e.get("series_key") == reference.get("series_key")
                 and e.get("regime_key") == reference.get("regime_key")]
        candidates = exact or [e for e in episodes if e.get("series_key") == reference.get("series_key")]
    else:
        candidates = [e for e in episodes if _belongs(str(e.get("series_key", "")), metric)]
    if not candidates:
        return None
    return max(candidates, key=lambda e: (EPISODE_RANK.get(e.get("state"), -1), str(e.get("last_day", "")),
                                          str(e.get("id", ""))))


def context_judgment(document: dict[str, Any] | None, metric: InsightMetric) -> dict[str, Any]:
    if not document:
        return {"available": False, "reason": "no_context_document"}
    comparisons = [c for c in document.get("comparisons") or [] if isinstance(c, dict)
                   and c.get("series_key") == metric.nightly_series]
    if not comparisons:  # no nightly comparison: the page's other series family members, like the app
        comparisons = [c for c in document.get("comparisons") or [] if isinstance(c, dict)
                       and _belongs(str(c.get("series_key", "")), metric)]
    reference = headline_reference(comparisons)
    episodes = [e for e in document.get("episodes") or [] if isinstance(e, dict)]
    episode = headline_episode(reference, episodes, metric)
    decimals = metric.signal.decimals
    out: dict[str, Any] = {"available": True, "status": document.get("status")}
    if reference:
        out["reference"] = {
            "series": reference.get("series_key"), "view": reference.get("view"), "status": reference.get("status"),
            "center": rounded(_num(reference.get("center")), decimals),
            "difference": rounded(_num(reference.get("signed_difference")), decimals),
            "robust_distance": rounded(_num(reference.get("robust_z")), 1),
            "support_nights": reference.get("support_days"),
            "from": reference.get("from_day"), "to": reference.get("to_day"),
        }
    if episode:
        out["episode"] = {"state": episode.get("state"), "direction": episode.get("direction"),
                          "start": episode.get("start_day"), "last": episode.get("last_day"),
                          "duration_nights": episode.get("duration_days"), "ongoing": episode.get("ongoing")}
    return out


def _num(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def availability_estimated(document: dict[str, Any] | None, signal: Signal) -> bool:
    """Whether the context document marks the signal as an estimate (e.g. respiratory rate from RSA only,
    an unverified SpO2 candidate). Falls back to the signal's default."""
    if document and signal.availability_metric:
        entries = [a for a in document.get("availability") or [] if isinstance(a, dict)
                   and a.get("metric") == signal.availability_metric]
        if entries:
            reasons = {r for a in entries for r in a.get("reasons") or []}
            states = {a.get("state") for a in entries}
            return bool("unverified" in states or any("estimate" in str(r) for r in reasons))
    return signal.estimated


# --------------------------------------------------------------------------- Layer 1 baseline rules (mirrored)
#
# The phone's Layer 1 Baseline (Packages/StrandAnalytics LongitudinalBaseline, parameter set v1.review; see
# docs/LAYER1_WATCHDOG_IN_NARA.md and docs/PORT_LAYER1_WATCHDOG.md §6) keeps its snapshots on the device. The same
# published rules are applied here to the server's nightly values, so an explanation speaks about "your usual"
# the way the Baseline card does. Inputs differ (nightly scores here, the minute tape there), so the two can
# differ slightly; the payload says which it is.

L1_WEEK_ALPHA = 2 / (7 + 1)     # 0.25
L1_WEEK_MIN_NIGHTS = 4
L1_LONG_FROM, L1_LONG_TO = 60, 8  # nights T-60 .. T-8 (53 slots): the newest week is never inside the long copy
L1_LONG_SHOWN, L1_LONG_ESTABLISHED = 4, 14
L1_BAND_K, L1_K_RANGE = 2.0, (1.5, 2.8)  # band = center +/- k*spread; after 14 nights k = p95 of clean |z|
L1_MAD_SCALE = 1.4826
L1_TRIM_Z, L1_TRIM_KEEP = 2.0, 0.65      # nights with |z| >= 2 are trimmed if at least 65% remain
L1_STALE_DAYS = 14
# Per series (LongitudinalBaseline.swift, v1.review): plausible range and spread floor (on the series' own scale:
# bpm for resting HR, ln(RMSSD) for HRV).
L1_SERIES = {"resting_hr": {"range": (30.0, 120.0), "floor": 2.0, "log": False},
             "hrv_rmssd": {"range": (5.0, 250.0), "floor": 0.08, "log": True}}


def layer1_baseline(values: dict[date, float], anchor: date, *, series: str, decimals: int) -> dict[str, Any]:
    """The two copies, never mixed: a 7-day finite EWMA of the 7 completed nights before the anchor, and the long
    copy (median and k-spread band of nights T-60..T-8, outliers trimmed). HRV is handled on ln(RMSSD), shown in ms.
    Tonight is scored, never trained."""
    spec = L1_SERIES[series]
    low_ok, high_ok = spec["range"]
    log_scale = spec["log"]
    values = {d: v for d, v in values.items() if v is not None and low_ok <= v <= high_ok}

    def fwd(v: float) -> float:
        return math.log(v) if log_scale else v

    def inv(v: float) -> float:
        return math.exp(v) if log_scale else v

    week_days = [anchor - timedelta(days=i) for i in range(1, 8)]          # newest first
    week = [(i, fwd(values[d])) for i, d in enumerate(week_days) if values.get(d) is not None]
    out: dict[str, Any] = {"rules": "Layer 1 v1.review, applied to nightly values on the server"}
    if week:
        weights = [L1_WEEK_ALPHA * (1 - L1_WEEK_ALPHA) ** i for i, _ in week]
        center = sum(w * v for w, (_, v) in zip(weights, week)) / sum(weights)
        out["week"] = {"center": rounded(inv(center), decimals), "nights": len(week),
                       "shown": len(week) >= L1_WEEK_MIN_NIGHTS,
                       "method": "weighted average of the 7 nights before, newest weighted most"}
    long_days = [anchor - timedelta(days=i) for i in range(L1_LONG_TO, L1_LONG_FROM + 1)]
    long_values = [fwd(values[d]) for d in long_days if values.get(d) is not None]
    trained = [d for d in values if d < anchor]
    if long_values:
        center = median(long_values)
        spread = max(L1_MAD_SCALE * median([abs(v - center) for v in long_values]), spec["floor"])
        kept = [v for v in long_values if abs(v - center) / spread < L1_TRIM_Z]
        if len(kept) >= L1_TRIM_KEEP * len(long_values) and len(kept) < len(long_values):
            center = median(kept)
            spread = max(L1_MAD_SCALE * median([abs(v - center) for v in kept]), spec["floor"])
        else:
            kept = long_values
        floored = spread <= spec["floor"]
        k = L1_BAND_K
        if len(long_values) >= L1_LONG_ESTABLISHED:
            k = min(max(quantile([abs(v - center) / spread for v in kept], 0.95), L1_K_RANGE[0]), L1_K_RANGE[1])
        out["long"] = {"center": rounded(inv(center), decimals), "low": rounded(inv(center - k * spread), decimals),
                       "high": rounded(inv(center + k * spread), decimals), "nights": len(long_values),
                       "band_width_k": round(k, 2), "spread_floored": floored,
                       "from": (anchor - timedelta(days=L1_LONG_FROM)).isoformat(),
                       "to": (anchor - timedelta(days=L1_LONG_TO)).isoformat(),
                       "shown": len(long_values) >= L1_LONG_SHOWN,
                       "established": len(long_values) >= L1_LONG_ESTABLISHED,
                       "stale": bool(trained) and (anchor - max(trained)).days > L1_STALE_DAYS,
                       "method": "median of nights 60 to 8 days before; the usual band is k robust spreads either "
                                 "side (k fitted to this person's own nights once 14 are in)"}
    return out


def position(value: float | None, band: dict[str, Any] | None) -> str:
    if value is None:
        return "not_measured"
    if not band or not band.get("shown") or band.get("low") is None:
        return "no_usual_yet"
    if value > band["high"]:
        return "above_usual_band"
    if value < band["low"]:
        return "below_usual_band"
    return "within_usual_band"


# --------------------------------------------------------------------------- tool payloads


def _tracked(series: list[tuple[date, float | None]]) -> list[tuple[date, float | None]]:
    """The nights from the first measured one on: earlier nights are before tracking began, not gaps."""
    first = next((i for i, (_, v) in enumerate(series) if v is not None), len(series))
    return series[first:]


def metric_series(scores: dict[date, dict[str, Any]], metric: InsightMetric, anchor: date, days: int) -> dict[str, Any]:
    signal = metric.signal
    series = nights(scores, signal, anchor - timedelta(days=days - 1), anchor)
    tracked = _tracked(series)
    measured = [v for _, v in tracked if v is not None]
    return {
        "metric": metric.key, "label": signal.label, "units": signal.units,
        "from": series[0][0].isoformat(), "to": anchor.isoformat(),
        "nights": [{"day": d.isoformat(), "value": rounded(v, signal.decimals)} for d, v in tracked],
        "measured_nights": len(measured), "missing_nights": len(tracked) - len(measured),
        "note": "starts at the first measured night; value null = not measured that night (missing, not zero)",
    }


def metric_summary(scores: dict[date, dict[str, Any]], metric: InsightMetric, anchor: date, window_days: int,
                   document: dict[str, Any] | None) -> dict[str, Any]:
    signal = metric.signal
    series = nights(scores, signal, anchor - timedelta(days=window_days - 1), anchor)
    measured = [(d, v) for d, v in series if v is not None]
    if not measured:
        return {"metric": metric.key, "measured_nights": 0, "assessment": {"basis": "no_measurements"}}
    d = signal.decimals
    latest_day, latest = measured[-1]
    out: dict[str, Any] = {
        "metric": metric.key, "label": signal.label, "units": signal.units,
        "estimated": availability_estimated(document, signal),
        "latest": {"day": latest_day.isoformat(), "value": rounded(latest, d)},
        "measured_nights": len(measured), "window": {"from": series[0][0].isoformat(), "to": anchor.isoformat()},
    }
    if len(measured) >= 2:
        prev_day, prev = measured[-2]
        out["previous"] = {"day": prev_day.isoformat(), "value": rounded(prev, d),
                           "change": shown_difference(latest, prev, d)}
    # The person's usual, by Layer 1's rules (the phone Baseline's): the 60-day copy once it is shown, else the
    # 7-night copy. One definition everywhere, so an explanation never shows two different "usual ranges".
    layer1 = layer1_baseline({day: v for day, v in measured if day < latest_day}, latest_day, series=metric.key,
                             decimals=d)
    long, week = layer1.get("long"), layer1.get("week")
    chosen = ("long", long) if long and long.get("shown") else ("week", week) if week and week.get("shown") else None
    baseline: dict[str, Any] = {"week": week, "long": long, "rules": layer1["rules"]}
    if chosen:
        name, copy = chosen
        change = shown_difference(latest, copy["center"], d)
        baseline.update(usual=name, usual_value=copy["center"], change_vs_usual=change,
                        direction=_direction(change, signal.flat))
        if name == "long":
            baseline.update(usual_low=long["low"], usual_high=long["high"])
    out["baseline"] = baseline
    recent = [v for day, v in measured if day > anchor - timedelta(days=RECENT_NIGHTS)]
    if recent:
        out["last_7_nights"] = {"measured": len(recent), "median": rounded(median(recent), d),
                                "low": rounded(min(recent), d), "high": rounded(max(recent), d)}
    context = context_judgment(document, metric)
    out["context_layer"] = context
    out["assessment"] = _assessment(rounded(latest, d), baseline, context)
    return out


def _assessment(latest: float | int | None, baseline: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Whether the latest night is unusual for this person, and on what basis: the context layer's own change
    detection when its reference is ready, else Layer 1's usual band, else the 7-night usual alone."""
    reference = context.get("reference") or {}
    episode = context.get("episode") or {}
    if reference.get("status") == "ready" and reference.get("difference") is not None:
        return {"basis": "context_layer", "state": episode.get("state") or "no_change_episode",
                "robust_distance": reference.get("robust_distance"),
                "note": "the app's own change detection against its personal reference"}
    long = baseline.get("long") or {}
    if long.get("shown"):
        return {"basis": "usual_band", "state": position(latest, long), "established": bool(long.get("established")),
                "note": "the 60-day usual band (Layer 1); before 14 older nights it is provisional"}
    if baseline.get("usual") == "week":
        return {"basis": "week_usual", "state": "compared_with_recent_nights",
                "note": "only the 7-night usual exists yet; a usual band needs older nights"}
    return {"basis": "insufficient_history", "nights_needed": L1_WEEK_MIN_NIGHTS,
            "note": "too few earlier measured nights to say what is usual for this person"}


def related_metrics(scores: dict[date, dict[str, Any]], metric: InsightMetric, anchor: date, window_days: int,
                    document: dict[str, Any] | None, keys: list[str] | None = None) -> dict[str, Any]:
    out = []
    for key in keys or list(metric.related):
        signal = SIGNALS.get(key)
        if signal is None:
            continue
        series = nights(scores, signal, anchor - timedelta(days=window_days - 1), anchor)
        measured = [(d, v) for d, v in series if v is not None]
        estimated = availability_estimated(document, signal)
        entry: dict[str, Any] = {"metric": key, "label": signal.label, "units": signal.units,
                                 "estimated": estimated, "measured_nights": len(measured)}
        if not measured:
            entry["latest"] = None
            out.append(entry)
            continue
        latest_day, latest = measured[-1]
        entry["latest"] = {"day": latest_day.isoformat(), "value": rounded(latest, signal.decimals)}
        entry["same_night_as_metric"] = latest_day == anchor
        usual, nights_used = None, 0
        if key in L1_SERIES:  # resting HR and HRV: the same Layer 1 usual as the metric itself
            layer1 = layer1_baseline({d: v for d, v in measured[:-1]}, latest_day, series=key, decimals=signal.decimals)
            copy = next((c for c in (layer1.get("long"), layer1.get("week")) if c and c.get("shown")), None)
            if copy:
                usual, nights_used = copy["center"], copy["nights"]
        else:  # the other nightly signals: the median of their recent nights
            stats = robust([v for _, v in measured[:-1][-BASELINE_NIGHTS:]])
            if stats:
                usual, nights_used = rounded(stats["median"], signal.decimals), stats["n"]
        if usual is not None:
            delta = shown_difference(latest, float(usual), signal.decimals)
            entry.update(usual=usual, change_vs_usual=delta, usual_nights=nights_used,
                         direction=_direction(delta, signal.flat))
        else:
            entry["direction"] = "unknown"
        out.append(entry)
    return {"anchor_day": anchor.isoformat(), "signals": out,
            "note": "estimated=true signals are model estimates, not direct measurements; say so when mentioning them"}


def _local_time(value: Any, zone: ZoneInfo) -> str | None:
    if not isinstance(value, datetime):
        return None
    moment = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return moment.astimezone(zone).strftime("%H:%M")


def sleep_context(scores: dict[date, dict[str, Any]], anchor: date, zone: ZoneInfo, count: int,
                  document: dict[str, Any] | None) -> dict[str, Any]:
    total, efficiency = SIGNALS["sleep_total"], SIGNALS["sleep_efficiency"]
    rows = []
    day = anchor - timedelta(days=count - 1)
    while day <= anchor:
        row = scores.get(day) or {}
        hours = plausible(total, row.get(total.column))
        rows.append({"day": day.isoformat(),
                     "duration_h": rounded(hours, 1),
                     "efficiency_pct": rounded(plausible(efficiency, row.get(efficiency.column)), 0),
                     "onset_local": _local_time(row.get("sleep_onset_at"), zone),
                     "wake_local": _local_time(row.get("wake_onset_at"), zone)})
        day += timedelta(days=1)
    durations = [plausible(total, (scores.get(d) or {}).get(total.column))
                 for d in (anchor - timedelta(days=i) for i in range(1, BASELINE_NIGHTS + 1))]
    durations = [v for v in durations if v is not None]
    out: dict[str, Any] = {"nights": rows, "estimated": True,
                           "note": "sleep timing and duration are estimated from motion and heart rate"}
    if durations:
        out["usual_duration_h"] = {"median": rounded(median(durations), 1), "nights": len(durations)}
    timing = ((document or {}).get("sleep") or {}).get("timing") if document else None
    if isinstance(timing, dict) and timing.get("state") == "available":
        out["timing_change"] = {
            "wake_shift_min": rounded(_num(timing.get("wake_change_s")) / 60.0, 0)
            if _num(timing.get("wake_change_s")) is not None else None,
            "midpoint_shift_min": rounded(_num(timing.get("midpoint_change_s")) / 60.0, 0)
            if _num(timing.get("midpoint_change_s")) is not None else None,
            "compared_with_nights": timing.get("support_nights"),
            "verifiable": bool(timing.get("change_verifiable")),
        }
    return out


# --------------------------------------------------------------------------- the metric by state and time of day

# Where the context layer measures each metric in a defined state (contracts: physiology context series keys).
STATE_SERIES: dict[str, tuple[tuple[str, str, str], ...]] = {
    "resting_hr": (("sleep", "during sleep", "resting_hr.sleep_night"),
                   ("awake_rest", "at calm awake rest", "heart_rate.stable_awake_5min"),
                   ("with_movement", "the rise in heart rate when you walked", "hr_response.stepping.")),
    "hrv_rmssd": (("sleep", "during sleep", "hrv_rmssd.sleep_night"),
                  ("awake_rest", "at calm awake rest", "hrv_rmssd.stable_awake_5min")),
}
TIME_BANDS = {"band_00_06": "between midnight and 6 am", "band_12_18": "between noon and 6 pm"}
NOT_ON_SERVER = {"hrv_rmssd": {"state": "with_movement", "label": "while moving", "available": False,
                               "reason": "not_measured_on_server",
                               "note": "HRV while moving is followed live on the phone (Watchdog); the server has no "
                                       "HRV for moving minutes, so do not describe it"}}


def _daily_value(document: dict[str, Any] | None, key: str) -> dict[str, Any] | None:
    """A context-layer daily value: exact key, or the best-supported one under a prefix ending with '.'."""
    values = [v for v in (document or {}).get("daily_values") or [] if isinstance(v, dict)
              and (v.get("series_key") == key or (key.endswith(".") and str(v.get("series_key", "")).startswith(key)
                                                  and ".band_" not in str(v.get("series_key"))))]
    return max(values, key=lambda v: _num(v.get("support_count")) or 0) if values else None


def _reference_band(comparisons: list[dict[str, Any]], decimals: int) -> dict[str, Any] | None:
    """The app's personal reference for a state series (headlineReference rules), with a band of 2 robust scales
    either side when the reference is ready."""
    reference = headline_reference(comparisons)
    if not reference:
        return None
    out: dict[str, Any] = {"source": "the app's personal reference for this state", "view": reference.get("view"),
                           "status": reference.get("status"), "nights": reference.get("support_days"),
                           "center": rounded(_num(reference.get("center")), decimals)}
    centre, scale = _num(reference.get("transformed_center")), _num(reference.get("scale"))
    if reference.get("status") == "ready" and centre is not None and scale:
        inverse = math.exp if reference.get("transform") == "ln" else (lambda v: v)
        out.update(low=rounded(inverse(centre - 2 * scale), decimals), high=rounded(inverse(centre + 2 * scale), decimals),
                   shown=True)
    else:
        out["shown"] = False
    return out


def state_breakdown(scores: dict[date, dict[str, Any]], metric: InsightMetric, anchor: date,
                    document: dict[str, Any] | None, snapshots: dict[date, dict[str, Any]] | None = None,
                    zone: ZoneInfo | None = None) -> dict[str, Any]:
    """The metric in each state the measurements define (sleep, calm awake rest, around movement) and by time of
    day, each against its own usual: Layer 1's rules for the nightly value, the context layer's personal reference
    for the others. A state the server does not measure is listed as such, never filled in."""
    signal, d = metric.signal, metric.signal.decimals
    nightly = {day: v for day, v in nights(scores, signal, anchor - timedelta(days=WINDOW_DAYS), anchor) if v is not None}
    states, unavailable = [], []
    for state, label, key in STATE_SERIES.get(metric.key, ()):
        entry: dict[str, Any] = {"state": state, "label": label}
        if state == "sleep":
            value = nightly.get(anchor)
            usual = layer1_baseline({k: v for k, v in nightly.items() if k < anchor}, anchor,
                                    series=metric.key, decimals=d)
            entry.update(value=rounded(value, d), units=signal.units, available=value is not None,
                         source="the night's score", usual=usual.get("long"), week=usual.get("week"),
                         position=position(rounded(value, d), usual.get("long")))
        else:
            daily = _daily_value(document, key)
            value = _num((daily or {}).get("value"))
            if value is None:  # not measured in this state today: listed apart, never next to measured states
                unavailable.append({"state": state, "label": label, "reason": "not_measured_in_this_state"})
                continue
            comparisons = [c for c in (document or {}).get("comparisons") or [] if isinstance(c, dict)
                           and (c.get("series_key") == (daily or {}).get("series_key", key))]
            usual = _reference_band(comparisons, d)
            entry.update(value=rounded(value, d), units=(daily or {}).get("units") or signal.units,
                         available=value is not None, source="the context layer's measurements for this state",
                         measured_in=f"{daily.get('support_count')} {daily.get('support_unit')}s" if daily else None,
                         usual=usual, position=position(rounded(value, d), usual))
            if state == "awake_rest":
                entry["time_of_day"] = [
                    {"when": words, "value": rounded(_num(v.get("value")), d)}
                    for band, words in TIME_BANDS.items()
                    if (v := _daily_value(document, f"{key}.{band}")) and _num(v.get("value")) is not None]
        states.append(entry)
    through_the_day = hrv_slot_states(snapshots or {}, zone) if metric.key == "hrv_rmssd" and zone else None
    if metric.key in NOT_ON_SERVER and not any(s["state"] == "while_moving" for s in
                                               (through_the_day or {}).get("states") or []):
        unavailable.append(dict(NOT_ON_SERVER[metric.key]))
    out = {"metric": metric.key, "night": anchor.isoformat(), "states": states, "not_measured": unavailable,
           "note": "each state has its own usual; compare a state only with its own usual, never across states; "
                   "states under not_measured were not measured, so say nothing about them"}
    if through_the_day and through_the_day["states"]:
        out["through_the_day"] = through_the_day
    return out


def movement_patterns(previous: dict[str, Any] | None, document: dict[str, Any] | None,
                      scores: dict[date, dict[str, Any]], anchor: date, zone: ZoneInfo,
                      runs: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """The movement before the anchor night (the previous day) and on the anchor day, with timings in the
    person's own time and the gap between the last movement and falling asleep. Decoded activity runs first;
    the context layer's bouts when there are none."""
    from_runs = movement_from_runs(runs or [], anchor, scores, zone)
    if from_runs is not None:
        return {"night": anchor.isoformat(), "estimated": True, **from_runs,
                "load": workout_context(previous).get("exertion_windows") if previous else None,
                "note": "movement is classified from wrist motion (estimated); the night is scored on the day it "
                        "ends, so 'before_the_night' is the day and evening before"}
    def bouts_of(doc: dict[str, Any] | None) -> list[dict[str, Any]]:
        out = []
        for bout in (doc or {}).get("bouts") or []:
            interval = bout.get("interval") or {} if isinstance(bout, dict) else {}
            start, end = _num(interval.get("start")), _num(interval.get("end"))
            if start is None or end is None or end <= start:
                continue
            out.append({"kind": bout.get("kind"), "start_local": _clock(start, zone), "end_local": _clock(end, zone),
                        "minutes": rounded((end - start) / 60.0, 0), "_end": end})
        return sorted(out, key=lambda b: b["_end"])
    before, after = bouts_of(previous), bouts_of(document)
    onset = (scores.get(anchor) or {}).get("sleep_onset_at")
    out: dict[str, Any] = {"night": anchor.isoformat(), "estimated": True,
                           "before_the_night": [{k: v for k, v in b.items() if k != "_end"} for b in before],
                           "on_the_day": [{k: v for k, v in b.items() if k != "_end"} for b in after],
                           "load": workout_context(previous).get("exertion_windows") if previous else None,
                           "note": "movement bouts are classified from wrist motion (estimated); the night is "
                                   "scored on the day it ends, so 'before_the_night' is the evening before"}
    if before and isinstance(onset, datetime):
        gap = (onset.timestamp() - before[-1]["_end"]) / 60.0
        if 0 <= gap <= 24 * 60:
            out["last_movement_before_sleep_min"] = rounded(gap, 0)
    return out


# --------------------------------------------------------------------------- HRV through the day, by state

SLOT_S = 900                       # the snapshot's HRV slots (DayScoring.hrvSlotSeconds)
MOVING_SHARES = ("walking", "running", "other_movement")
MOVING_SHARE_MIN = 0.25            # a slot with at least this share of movement counts as "while moving"
CALM_SHARE_MIN = 0.8               # and one at least this still (and not just after activity) as calm awake
AFTER_MOVEMENT_S = 1800            # within 30 minutes of the end of supported activity
SLOT_STATES = {"sleep": "during sleep", "calm_awake": "while calm and awake", "after_movement": "in the half hour "
               "after moving", "while_moving": "while moving", "mixed": "mixed activity"}


def _epoch(value: Any) -> float | None:
    if isinstance(value, datetime):  # timestamptz columns arrive as datetimes
        return (value if value.tzinfo else value.replace(tzinfo=timezone.utc)).timestamp()
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def hrv_slot_states(snapshots: dict[date, dict[str, Any]], zone: ZoneInfo) -> dict[str, Any]:
    """The night's two days of 15-minute HRV readings, each placed in a state by the activity the hosted snapshot
    paired with it (contexts.hrv_slots) and the sleep sessions. Medians per state; awake readings are noisier than
    sleep ones (the worker publishes them as spot readings, not a baseline), so states are compared within these
    days, not with the nightly usual."""
    points, contexts, sessions = {}, {}, []
    for payload in snapshots.values():
        daily = payload.get("daily") or {}
        for point in (daily.get("hrv_series") or {}).get("points") or []:
            if isinstance(point, list) and len(point) >= 3 and _num(point[1]) and _num(point[0]) is not None:
                points[int(point[0])] = (float(point[1]), int(point[2] or 0))
        activity = (daily.get("activity_context") or {}).get("contexts") or {}
        for slot in activity.get("hrv_slots") or []:
            if isinstance(slot, dict) and _num(slot.get("slot_s")) is not None:
                contexts[int(slot["slot_s"])] = slot
        for session in (payload.get("sleep") or []) + (activity.get("sleep_sessions") or []):
            start = _epoch(session.get("start_at", session.get("start")))
            end = _epoch(session.get("end_at", session.get("end")))
            if start is not None and end is not None and end > start and not session.get("is_nap"):
                sessions.append((start, end))
    by_state: dict[str, list[tuple[int, float]]] = {}
    for slot, (rmssd, _) in sorted(points.items()):
        middle = slot + SLOT_S / 2
        ctx = contexts.get(slot)
        if any(start <= middle < end for start, end in sessions):
            state = "sleep"
        elif ctx is None:
            continue  # no activity composition for this reading: not placed in a state
        else:
            shares = ctx.get("shares") or {}
            moving = sum(_num(shares.get(k)) or 0.0 for k in MOVING_SHARES)
            recent = _num(ctx.get("recent_activity_s"))
            if moving >= MOVING_SHARE_MIN:
                state = "while_moving"
            elif ctx.get("post_activity") or (recent is not None and recent <= AFTER_MOVEMENT_S):
                state = "after_movement"
            elif (_num(shares.get("stationary")) or 0.0) >= CALM_SHARE_MIN:
                state = "calm_awake"
            else:
                state = "mixed"
        by_state.setdefault(state, []).append((slot, rmssd))
    states = []
    for state in SLOT_STATES:
        readings = by_state.get(state)
        if not readings:
            continue
        values = [v for _, v in readings]
        states.append({"state": state, "label": SLOT_STATES[state], "median_ms": rounded(median(values), 0),
                       "low_ms": rounded(min(values), 0), "high_ms": rounded(max(values), 0),
                       "readings": len(values), "minutes": len(values) * SLOT_S // 60,
                       "from_local": _clock(readings[0][0], zone),
                       "to_local": _clock(readings[-1][0] + SLOT_S, zone)})
    return {"slot_minutes": SLOT_S // 60, "states": states,
            "note": "15-minute HRV readings grouped by what you were doing; awake readings are noisier than sleep "
                    "ones, so compare these states with each other, not with your nightly usual"}


MOVING_CLASSES = {"walking": "walking", "brisk_walking": "brisk walking", "running": "running", "cycling": "cycling",
                  "vigorous_activity": "vigorous activity", "light_activity": "light activity"}
MERGE_GAP_S = 120


def movement_from_runs(runs: list[dict[str, Any]], anchor: date, scores: dict[date, dict[str, Any]],
                       zone: ZoneInfo) -> dict[str, Any] | None:
    """Movement from the decoded activity runs: bouts (same class, gaps up to 2 minutes merged) the day before the
    anchor night and on the anchor day, minutes per kind, and how long before sleep the last one ended."""
    if not runs:
        return None
    onset = _epoch((scores.get(anchor) or {}).get("sleep_onset_at"))
    wake = _epoch((scores.get(anchor) or {}).get("wake_onset_at"))
    day_start = datetime.combine(anchor - timedelta(days=1), datetime.min.time(), zone).timestamp()
    bouts: list[dict[str, Any]] = []
    for run in sorted(runs, key=lambda r: r["start_ts"]):
        kind = MOVING_CLASSES.get(str(run.get("activity_class")))
        if kind is None:
            continue
        start, end = float(run["start_ts"]), float(run["end_ts"])
        if bouts and bouts[-1]["kind"] == kind and start - bouts[-1]["_end"] <= MERGE_GAP_S:
            bouts[-1]["_end"] = max(bouts[-1]["_end"], end)
        else:
            bouts.append({"kind": kind, "_start": start, "_end": end})
    def shown(group: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return [{"kind": b["kind"], "start_local": _clock(b["_start"], zone), "end_local": _clock(b["_end"], zone),
                 "minutes": rounded((b["_end"] - b["_start"]) / 60.0, 0)} for b in group
                if b["_end"] - b["_start"] >= 60]
    before = [b for b in bouts if b["_start"] >= day_start and (onset is None or b["_end"] <= onset)]
    after = [b for b in bouts if wake is not None and b["_start"] >= wake]
    totals: dict[str, float] = {}
    for b in before:
        totals[b["kind"]] = totals.get(b["kind"], 0.0) + (b["_end"] - b["_start"]) / 60.0
    out: dict[str, Any] = {"before_the_night": shown(before), "on_the_day": shown(after),
                           "minutes_by_kind_before_the_night": {k: rounded(v, 0) for k, v in totals.items()},
                           "source": "decoded activity runs"}
    if before and onset is not None:
        gap = (onset - before[-1]["_end"]) / 60.0
        if 0 <= gap <= 24 * 60:
            out["last_movement_before_sleep_min"] = rounded(gap, 0)
    return out


def _clock(epoch: float, zone: ZoneInfo) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).astimezone(zone).strftime("%H:%M")


def workout_context(document: dict[str, Any] | None) -> dict[str, Any]:
    if not document:
        return {"available": False, "reason": "no_context_document"}
    windows = []
    for entry in document.get("exertion") or []:
        if not isinstance(entry, dict):
            continue
        locomotion, observed = _num(entry.get("locomotion_s")), _num(entry.get("observed_s"))
        # Unknown stays unknown (the contract's nil): a strap that was off is not "no training load".
        windows.append({"hours": entry.get("window_h"), "bouts": entry.get("bout_count"),
                        "locomotion_min": rounded(locomotion / 60.0, 0) if locomotion is not None else None,
                        "observed_h": rounded(observed / 3600.0, 1) if observed is not None else None})
    bouts: dict[str, dict[str, Any]] = {}
    for bout in document.get("bouts") or []:
        if not isinstance(bout, dict):
            continue
        interval = bout.get("interval") or {}
        start, end = _num(interval.get("start")), _num(interval.get("end"))
        kind = str(bout.get("kind") or "movement")
        slot = bouts.setdefault(kind, {"kind": kind, "count": 0, "minutes": 0})
        slot["count"] += 1
        if start is not None and end is not None and end > start:
            slot["minutes"] += round((end - start) / 60.0)
    return {"available": True, "exertion_windows": sorted(windows, key=lambda w: w.get("hours") or 0),
            "movement_bouts": sorted(bouts.values(), key=lambda b: -b["minutes"]), "estimated": True,
            "note": "movement bouts are classified from wrist motion; locomotion minutes are an estimate of training load"}


def _per(value: float | None, divisor: float, decimals: int) -> float | int | None:
    return rounded(value / divisor, decimals) if value is not None else None


def activity_context(document: dict[str, Any] | None) -> dict[str, Any]:
    if not document:
        return {"available": False, "reason": "no_context_document"}
    values = {}
    for value in document.get("daily_values") or []:
        if isinstance(value, dict) and str(value.get("series_key", "")).startswith(("functional.", "coverage.")):
            values[value["series_key"]] = _num(value.get("value"))
    worn = values.get("coverage.motion_observed_s")
    return {"available": True, "estimated": True,
            "worn_h": rounded(worn / 3600.0, 1) if worn is not None else None,
            "locomotion_min_per_worn_hour": _per(values.get("functional.locomotion_s_per_worn_hour"), 60.0, 1),
            "bouts_per_worn_hour": rounded(values.get("functional.bouts_per_worn_hour"), 2),
            "median_bout_min": _per(values.get("functional.median_bout_s"), 60.0, 1),
            "note": "daily activity level from wrist motion (estimated)"}


def recent_events(exposures: list[dict[str, Any]], document: dict[str, Any] | None, zone: ZoneInfo) -> dict[str, Any]:
    events = []
    for event in exposures:
        if event.get("confirmation") != "confirmed":
            continue
        start = datetime.fromtimestamp(int(event["occurred_start"]), tz=timezone.utc).astimezone(zone)
        hidden = event.get("kind") in ("medication", "supplement")  # a drug is never named (Layer 1's rule too)
        entry = {"kind": event.get("kind"), "label": None if hidden else event.get("label"),
                 "local_day": start.date().isoformat(),
                 "local_time": start.strftime("%H:%M") if event.get("time_precision") != "day_only" else None}
        if hidden:
            entry["note"] = "logged; never name it or link it to a change"
        elif event.get("dose_amount") is not None:
            entry["dose"] = rounded(_num(event.get("dose_amount")), 1)
            entry["dose_unit"] = event.get("dose_unit")
        events.append(entry)
    unrecorded = []
    exposure_doc = (document or {}).get("exposures") if document else None
    if isinstance(exposure_doc, dict):
        unrecorded = sorted({str(c.get("kind")) for c in exposure_doc.get("category_status") or []
                             if isinstance(c, dict) and c.get("status") == "unrecorded"})
    return {"events": events, "unrecorded_categories": unrecorded,
            "note": "only what the person recorded; an unrecorded category means unknown, not absent"}


def data_quality(scores: dict[date, dict[str, Any]], metric: InsightMetric, anchor: date, window_days: int,
                 document: dict[str, Any] | None, context_mode: str | None) -> dict[str, Any]:
    series = nights(scores, metric.signal, anchor - timedelta(days=window_days - 1), anchor)
    tracked = _tracked(series)
    measured = [d for d, v in tracked if v is not None]
    out: dict[str, Any] = {
        "tracked_nights": len(tracked),
        "measured_nights": len(measured),
        "missing_nights": len(tracked) - len(measured),
        "first_measured": measured[0].isoformat() if measured else None,
        "last_measured": measured[-1].isoformat() if measured else None,
        "longest_gap_nights": _longest_gap(tracked),
        "measured_in_last_7": sum(1 for d in measured if d > anchor - timedelta(days=RECENT_NIGHTS)),
        "note": "tracked = nights since the first measurement; missing = tracked nights without a measurement",
    }
    if document:
        statuses: dict[str, int] = {}
        for comparison in document.get("comparisons") or []:
            if isinstance(comparison, dict) and _belongs(str(comparison.get("series_key", "")), metric):
                statuses[str(comparison.get("status"))] = statuses.get(str(comparison.get("status")), 0) + 1
        out["context_layer"] = {"available": True, "mode": context_mode, "status": document.get("status"),
                                "comparison_statuses": statuses}
        availability = [a for a in document.get("availability") or [] if isinstance(a, dict)
                        and a.get("metric") == metric.signal.availability_metric and a.get("assessment") != "measurement_product"]
        if availability:
            out["signal_validity"] = {"state": availability[0].get("state"),
                                      "reasons": list(availability[0].get("reasons") or [])[:4]}
    else:
        out["context_layer"] = {"available": False}
    return out


def user_context(memory: list[dict[str, Any]]) -> dict[str, Any]:
    return {"items": [{"topic": m.get("topic"), "note": m.get("content"), "importance": m.get("importance")}
                      for m in memory],
            "note": "things this person told the coach; use only when directly relevant, never as a diagnosis"}


def chat_history(messages: list[dict[str, Any]] | None) -> dict[str, Any]:
    if messages is None:
        return {"available": False, "reason": "not_connected", "messages": [],
                "note": "coach conversations are not connected for analysis yet; say nothing about them"}
    return {"available": True, "messages": messages,
            "note": "this person's own words; use only what is directly relevant, never as a diagnosis"}


def health_records(records: dict[str, Any] | None) -> dict[str, Any]:
    if records is None:
        return {"available": False, "reason": "not_connected", "conditions": [], "medications": [], "labs": [],
                "note": "no health records are connected yet; say nothing about conditions or medications"}
    return {"available": True, **records,
            "note": "context only: never name a condition or a medication as the reason for a change"}


def previous_insight(row: dict[str, Any] | None) -> dict[str, Any]:
    if not row:
        return {"available": False}
    insight = row.get("insight") or {}
    return {"available": True, "data_through": str(row.get("anchor_day")) if row.get("anchor_day") else None,
            "headline": insight.get("headline")}


def metric_for(key: str) -> InsightMetric:
    return INSIGHT_METRICS[key]
