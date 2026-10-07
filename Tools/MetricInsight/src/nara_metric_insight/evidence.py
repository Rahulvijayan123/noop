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

from .metrics import (BASELINE_NIGHTS, EPISODE_RANK, INSIGHT_METRICS, REFERENCE_ORDER, SIGNALS, InsightMetric,
                      Signal, plausible)

MIN_RANGE_NIGHTS = 7          # nights before the latest needed for a personal usual range
RECENT_NIGHTS = 7             # the "last 7 nights" window
UNUSUAL_Z = 2.0               # robust distance at which a night reads as unusual for this person


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
    prior = measured[:-1][-BASELINE_NIGHTS:]
    stats = robust([v for _, v in prior])
    if stats:
        change = shown_difference(latest, stats["median"], d)
        out["baseline"] = {
            "nights": stats["n"], "from": prior[0][0].isoformat(), "to": prior[-1][0].isoformat(),
            "median": rounded(stats["median"], d),
            "change_vs_median": change,
            "direction": _direction(change, signal.flat),
            "method": f"median of up to {BASELINE_NIGHTS} measured nights before the latest",
        }
        if stats["n"] >= MIN_RANGE_NIGHTS:
            out["baseline"]["usual_range"] = {"low": rounded(stats["p25"], d), "high": rounded(stats["p75"], d),
                                              "method": "middle half (25th-75th percentile) of those nights"}
    recent = [v for day, v in measured if day > anchor - timedelta(days=RECENT_NIGHTS)]
    if recent:
        out["last_7_nights"] = {"measured": len(recent), "median": rounded(median(recent), d),
                                "low": rounded(min(recent), d), "high": rounded(max(recent), d)}
    context = context_judgment(document, metric)
    out["context_layer"] = context
    out["assessment"] = _assessment(latest, stats, context, signal)
    return out


def _assessment(latest: float, stats: dict[str, float] | None, context: dict[str, Any],
                signal: Signal) -> dict[str, Any]:
    """Whether the latest night is unusual for this person, and on what basis."""
    reference = context.get("reference") or {}
    episode = context.get("episode") or {}
    if reference.get("status") == "ready" and reference.get("difference") is not None:
        return {"basis": "context_layer", "state": episode.get("state") or "no_change_episode",
                "robust_distance": reference.get("robust_distance"),
                "note": "the app's own change detection against its personal reference"}
    if not stats or stats["n"] < MIN_RANGE_NIGHTS:
        return {"basis": "insufficient_history", "nights_available": stats["n"] if stats else 0,
                "nights_needed": MIN_RANGE_NIGHTS,
                "note": "too few earlier measured nights to say what is usual for this person"}
    scale = 1.4826 * stats["mad"]
    distance = (latest - stats["median"]) / scale if scale > 0 else None
    if stats["p25"] <= latest <= stats["p75"]:
        state = "within_usual_range"
    elif distance is not None and abs(distance) >= UNUSUAL_Z:
        state = "unusual_for_this_person"
    else:
        state = "near_usual_range"
    return {"basis": "personal_range", "state": state, "robust_distance": rounded(distance, 1),
            "note": "fallback while the app's personal reference is not ready: position within the measured nights"}


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
        stats = robust([v for _, v in measured[:-1][-BASELINE_NIGHTS:]])
        entry["latest"] = {"day": latest_day.isoformat(), "value": rounded(latest, signal.decimals)}
        entry["same_night_as_metric"] = latest_day == anchor
        if stats:
            delta = shown_difference(latest, stats["median"], signal.decimals)
            entry["median"] = rounded(stats["median"], signal.decimals)
            entry["change_vs_median"] = delta
            entry["baseline_nights"] = stats["n"]
            entry["direction"] = _direction(delta, signal.flat)
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
        entry = {"kind": event.get("kind"), "label": event.get("label"), "local_day": start.date().isoformat(),
                 "local_time": start.strftime("%H:%M") if event.get("time_precision") != "day_only" else None}
        if event.get("dose_amount") is not None:
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
