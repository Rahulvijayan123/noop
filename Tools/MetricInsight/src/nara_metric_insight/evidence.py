"""Deterministic evidence. Every number an explanation may state is computed here, never by the model.

Pure functions over the sources loaded for one job (sources.py). Conventions:
* A night without a plausible measurement is `None` — missing, never zero, never interpolated.
* Values are display values (metrics.Signal.scale) rounded to the signal's display precision; statistics are
  computed on unrounded values and rounded once at the end.
* The person's usual for a night vital, and the call for the night ("in range", "off usual"), are the app's Baseline
  (layer1.py, pinned to the app's own results). The context layer's judgments (reference comparisons and change
  episodes, chosen with the app's rules: MeasurementContextSelection.headlineReference / .episode) sit next to them.
"""

from __future__ import annotations

import math
from datetime import date, datetime, time, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal
from statistics import median
from typing import Any
from zoneinfo import ZoneInfo

from . import gait, layer1
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
                   and metric.context_series and c.get("series_key") == metric.context_series]
    if not comparisons:  # no comparison of the value's own series: the page's other family members, like the app
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


# --------------------------------------------------------------------------- the person's usual (the app's Baseline)
#
# The app's Baseline (Layer 1: LongitudinalBaseline, parameter set v2.clinical) runs here as layer1.py, pinned to the
# app's own results (tests/test_layer1.py), so an explanation calls a night inside or outside its usual exactly as
# the Home ring and the Monitor do from the same nightly values, replayed over the whole history as the phone does.
# Day logs, confounders and treatment trials live on the phone; they are neutral here, as on a phone with none logged.

# The Home ring's night vitals (BaselineStore.vitalsCheckSeries), in its order: the Layer 1 series, the app's name for
# it, the label and unit here, the decimals the Monitor prints, and the signal whose availability says measured or
# estimated.
NIGHT_VITALS = (("sleep_rhr", "Resting HR", "Resting heart rate", "bpm", 0, "resting_hr"),
                ("sleep_hrv_ln", "HRV", "HRV", "ms", 0, "hrv_rmssd"),
                ("sleep_temp", "Wrist temp", "Wrist temperature", "°C", 1, "skin_temp_dev"),
                ("sleep_resp", "Resp", "Respiratory rate", "breaths/min", 1, "resp_rate"),
                ("sleep_spo2_mean", "SpO₂", "Blood oxygen", "%", 0, "spo2"))
APP_LABELS = {layer1.IN_RANGE: "In range", layer1.OFF: "Off usual", layer1.LEARNING: "Learning",
              layer1.NO_READING: "No reading"}
# The call in the words `position` uses for the other states (off: above_ or below_usual_band).
CALL_POSITION = {layer1.IN_RANGE: "within_usual_band", layer1.LEARNING: "no_usual_yet",
                 layer1.NO_READING: "not_measured"}


def app_rounded(value: float | None, decimals: int) -> float | int | None:
    """A Baseline number as the app prints it (String(format: "%.0f"): the binary value rounded, ties to even), so a
    band said in an explanation is the band on the Monitor."""
    if value is None or not math.isfinite(value):
        return None
    shown = float(format(value, f".{max(decimals, 0)}f")) + 0.0
    return int(shown) if decimals <= 0 else shown


def app_baseline(history: dict[date, dict[str, Any]], series: str, night: date, decimals: int) -> dict[str, Any]:
    """One night vital against the person's usual as the app's Baseline computes and shows it: the week usual and the
    60-day usual (each with its band, its nights and whether the app trusts it enough to show it) and the app's call
    for the night, with the band it shows next to it."""
    ev = layer1.evaluate_rows(history, night, series)
    call = layer1.verdict(ev)

    def copy(c: layer1.Copy | None, shown: bool, trust: int, method: str, **extra: Any) -> dict[str, Any] | None:
        if c is None:
            return None
        return {"center": app_rounded(c.center_display, decimals), "low": app_rounded(c.band_lo_display, decimals),
                "high": app_rounded(c.band_hi_display, decimals), "nights": c.n,
                "shown_by_the_app": shown and trust >= layer1.TRUST_HIDE_THRESHOLD, "method": method, **extra}

    nights = layer1.SERIES[series].span7
    week = copy(ev.copy7, ev.show7, ev.trust7, f"weighted average of the {nights} nights before, newest weighted most")
    # slow_trend_detected: a significant slow trend in the newest 28 of those nights, reported only (the usual never
    # follows it). held_after_a_change: a change was detected and the usual is still the pre-change one.
    long = copy(ev.copy_long, ev.show_long, ev.trust_long,
                "median of the nights 60 to 8 days before; the band is a Student-t interval using the effective number "
                "of independent nights, widened by how the person's own recent nights actually fell; a slow trend is "
                "tested for significance and reported, never moves the usual; a detected change keeps the pre-change "
                "usual for 28 days", established=ev.established_long,
                slow_trend_detected=ev.slope_usable, held_after_a_change=ev.holding_copy)
    outside = [name for name, off in (("this_week", call.off_week), ("60_days", call.off_long)) if off]
    z = ev.z7 if call.off_week else ev.z_long
    return {"night": night.isoformat(), "value": app_rounded(call.value, decimals),
            "call": {"state": call.state, "app_label": APP_LABELS[call.state],
                     "shown_usual": None if call.band_lo is None else "this_week" if call.from_week else "60_days",
                     "low": app_rounded(call.band_lo, decimals), "high": app_rounded(call.band_hi, decimals),
                     "outside": outside, "side": ("above" if z > 0 else "below") if outside and z is not None else None},
            "week": week, "long": long,
            "rules": "the app's Baseline (Layer 1, v2.clinical) on the server's nightly values"}


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
                   document: dict[str, Any] | None, history: dict[date, dict[str, Any]] | None = None) -> dict[str, Any]:
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
    # The person's usual, defined as the app defines it for this metric: its Baseline (the week usual when the app
    # trusts it, else the 60-day one, and its call for the night), the context layer's reference, or, where the app
    # shows no usual, the person's recent measured periods. One definition everywhere, so an explanation never shows
    # a "usual range" the app does not.
    context = context_judgment(document, metric)
    if metric.usual == "app_baseline":
        baseline = app_baseline(scores if history is None else history, signal.layer1, latest_day, d)
        shown = _shown_usual(baseline)
        if shown:
            change = rounded(float(rounded(latest, d)) - float(shown["center"]), d)
            baseline.update(usual="week" if baseline["call"]["shown_usual"] == "this_week" else "long",
                            usual_value=shown["center"],
                            usual_low=shown["low"], usual_high=shown["high"], change_vs_usual=change,
                            direction=_direction(change, signal.flat))
    elif metric.usual == "context_layer":
        baseline = context_usual(context, latest_day, rounded(latest, d), signal)
    else:
        baseline = recent_usual(measured, latest_day, latest, signal, metric.period)
    out["baseline"] = baseline
    recent = [v for day, v in measured if day > anchor - timedelta(days=RECENT_NIGHTS)]
    if recent:
        out["last_7_nights"] = {"measured": len(recent), "median": rounded(median(recent), d),
                                "low": rounded(min(recent), d), "high": rounded(max(recent), d)}
    out["context_layer"] = context
    out["assessment"] = _assessment(baseline, context)
    out["period"] = metric.period
    return out


def _shown_usual(baseline: dict[str, Any]) -> dict[str, Any] | None:
    """The usual whose band the app shows next to its call (None while it is still learning)."""
    return {"this_week": baseline.get("week"), "60_days": baseline.get("long")}.get(baseline["call"].get("shown_usual"))


# The app's words for a context-layer change-episode state (MeasurementContextWording.episodeState).
CONTEXT_STATES = {"usual_variation": "Within usual variation", "transient_deviation": "Transient deviation from reference",
                  "recurring_episode": "Recurring deviation from reference",
                  "persistent_shift": "Persistent change from your recent usual range",
                  "insufficient_evidence": "Insufficient evidence for a change"}


def context_usual(context: dict[str, Any], day: date, value: float | int | None, signal: Signal) -> dict[str, Any]:
    """The context layer's view of the day, as the app's Measurement context page words it: the value against its
    personal reference ("+3 bpm vs your rolling reference") and the change-episode state ("Within usual variation",
    "Transient deviation from reference", ...). The call follows that state; with no ready reference it is learning."""
    reference, episode = context.get("reference") or {}, context.get("episode") or {}
    ready = reference.get("status") == "ready" and reference.get("center") is not None
    current = bool(episode) and bool(episode.get("ongoing") or episode.get("last") == day.isoformat())
    state = episode.get("state") if current else "usual_variation" if ready else None
    if not ready or state in (None, "insufficient_evidence"):
        call = {"state": "learning", "app_label": "No usual yet", "side": None}
    elif state == "usual_variation":
        call = {"state": "in_range", "app_label": CONTEXT_STATES["usual_variation"], "side": None}
    else:
        difference = _num(reference.get("difference")) or 0.0
        direction = _num(episode.get("direction")) or (1 if difference > 0 else -1 if difference < 0 else 0)
        call = {"state": "off", "app_label": CONTEXT_STATES.get(state, state),
                "side": "above" if direction > 0 else "below" if direction < 0 else None}
    out: dict[str, Any] = {"night": day.isoformat(), "value": value, "call": dict(call, context_state=state),
                           "rules": "the context layer's personal reference and change detection (Measurement context)"}
    if ready:
        out.update(usual="context_reference", usual_value=reference["center"], change_vs_usual=reference.get("difference"),
                   direction=_direction(_num(reference.get("difference")), signal.flat),
                   reference={k: reference.get(k) for k in ("view", "support_nights", "from", "to")})
    return out


def recent_usual(measured: list[tuple[date, float]], day: date, value: float, signal: Signal,
                 period: str) -> dict[str, Any]:
    """Where the app shows no usual (SDNN, the SpO2 estimate, calories): the person's last measured periods, as
    plain facts (median, lowest, highest, where the latest falls), never an in-or-out-of-range call."""
    d = signal.decimals
    earlier = [v for day_, v in measured if day_ < day][-BASELINE_NIGHTS:]
    out: dict[str, Any] = {"night": day.isoformat(), "value": rounded(value, d),
                           "call": {"state": "no_usual", "app_label": None, "side": None},
                           "rules": f"no usual in the app: compared with the last measured {period}s only"}
    if len(earlier) >= 3:
        middle = median(earlier)
        change = rounded(float(rounded(value, d)) - float(rounded(middle, d)), d)
        below = sum(1 for v in earlier if v < value)
        position = ("lowest" if value < min(earlier) else "highest" if value > max(earlier) else
                    "below_most" if below < len(earlier) / 4 else "above_most" if below > 3 * len(earlier) / 4 else
                    "within")
        out.update(usual="recent", usual_value=rounded(middle, d), change_vs_usual=change,
                   direction=_direction(change, signal.flat),
                   recent={"periods": len(earlier), "median": rounded(middle, d), "lowest": rounded(min(earlier), d),
                           "highest": rounded(max(earlier), d), "position": position, "lower_than_latest": below})
    return out


def _assessment(baseline: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Whether the night (or day) is unusual for this person: the app's own call (the Home ring and the Monitor for
    its Baseline vitals; the Measurement context page's episode state for stable awake heart rate) and, when its
    reference is ready, the context layer's change detection over the recent weeks. Where the app shows no usual,
    only the comparison with recent periods."""
    call = baseline["call"]
    basis = ("context_layer" if "context_state" in call else "recent_periods" if call["state"] == "no_usual"
             else "app_baseline")
    out: dict[str, Any] = {
        "basis": basis, "state": call["state"], "app_label": call.get("app_label"), "side": call.get("side"),
        "outside": call.get("outside", []), "shown_usual": call.get("shown_usual"),
        "note": "the app's call: in_range = inside the usual it shows; off = outside a usual it trusts (side says "
                "above or below; outside names which: this_week, 60_days); learning = no usual it trusts yet; "
                "no_reading = not measured; no_usual = the app shows no usual for this metric (compare with recent "
                "periods only, never call it in or out of a usual range)"}
    reference = context.get("reference") or {}
    if basis != "context_layer" and reference.get("status") == "ready" and reference.get("difference") is not None:
        out["change_detection"] = {"state": (context.get("episode") or {}).get("state") or "no_change_episode",
                                   "robust_distance": reference.get("robust_distance"),
                                   "note": "the context layer's change detection against its personal reference"}
    return out


def related_metrics(scores: dict[date, dict[str, Any]], metric: InsightMetric, anchor: date, window_days: int,
                    document: dict[str, Any] | None, keys: list[str] | None = None,
                    history: dict[date, dict[str, Any]] | None = None) -> dict[str, Any]:
    history = scores if history is None else history
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
        if signal.layer1:  # the app's own usual and call, as for the metric itself
            baseline = app_baseline(history, signal.layer1, latest_day, signal.decimals)
            entry["app_call"] = baseline["call"]["state"]
            shown = _shown_usual(baseline)
            if shown:
                usual, nights_used = shown["center"], shown["nights"]
                entry.update(usual_low=shown["low"], usual_high=shown["high"])
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
    return {"anchor_day": anchor.isoformat(), "signals": out, "night_vitals": night_vitals(history, anchor, document),
            "note": "estimated=true signals are model estimates, not direct measurements; say so when mentioning them"}


def night_vitals(history: dict[date, dict[str, Any]], night: date, document: dict[str, Any] | None) -> dict[str, Any]:
    """The Home ring for the night: each night vital against its own usual, exactly as the app shows it, and the
    ring's line (BaselineVitalsCheck.statusLine: "4 of 5 in range")."""
    vitals = []
    for series, app_name, label, units, decimals, signal in NIGHT_VITALS:
        baseline = app_baseline(history, series, night, decimals)
        call = baseline["call"]
        vitals.append({"vital": series, "app_name": app_name, "label": label, "units": units,
                       "value": baseline["value"], "state": call["state"], "app_label": call["app_label"],
                       "usual_low": call["low"], "usual_high": call["high"], "shown_usual": call["shown_usual"],
                       "side": call["side"], "estimated": availability_estimated(document, SIGNALS[signal])})
    counted = [v for v in vitals if v["state"] in (layer1.IN_RANGE, layer1.OFF)]
    in_range = sum(v["state"] == layer1.IN_RANGE for v in vitals)
    line = (f"{in_range} of {len(counted)} in range" if counted
            else "Learning" if any(v["state"] == layer1.LEARNING for v in vitals) else "No reading")
    return {"night": night.isoformat(), "vitals": vitals, "status_line": line,
            "note": "the app's Home ring and Monitor list for this night; each vital against its own usual only"}


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
                   ("awake_rest", "at stable awake rest", "heart_rate.stable_awake_5min"),
                   ("with_movement", "the rise in heart rate when you walked", "hr_response.stepping.")),
    "hrv_rmssd": (("sleep", "during sleep", "hrv_rmssd.sleep_night"),
                  ("awake_rest", "at stable awake rest", "hrv_rmssd.stable_awake_5min")),
    # Stable awake heart rate is itself the awake-rest series: its states are the time of day and movement.
    "heart_rate": (("awake_rest", "at stable awake rest", "heart_rate.stable_awake_5min"),
                   ("with_movement", "the rise in heart rate when you walked", "hr_response.stepping.")),
}
TIME_BANDS = {"band_00_06": "between midnight and 6 am", "band_06_12": "between 6 am and noon",
              "band_12_18": "between noon and 6 pm", "band_18_24": "between 6 pm and midnight"}
NOT_ON_SERVER = {"hrv_rmssd": {"state": "with_movement", "label": "while moving", "available": False,
                               "reason": "not_measured_on_server",
                               "note": "HRV while moving is followed live on the phone (Watchdog); the server has no "
                                       "HRV for moving minutes, so do not describe it"}}


def _daily_value(document: dict[str, Any] | None, key: str) -> dict[str, Any] | None:
    """A context-layer daily value: exact key, or one under a prefix ending with '.'; of several, the best supported
    (windows, then seconds), then the first regime key, as the app's chart picks (KeyMetricValues.contextDaily)."""
    values = [v for v in (document or {}).get("daily_values") or [] if isinstance(v, dict)
              and (v.get("series_key") == key or (key.endswith(".") and str(v.get("series_key", "")).startswith(key)
                                                  and ".band_" not in str(v.get("series_key"))))]
    return min(values, key=lambda v: (-(_num(v.get("support_count")) or 0), -(_num(v.get("support_s")) or 0),
                                      str(v.get("regime_key") or ""))) if values else None


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
                    zone: ZoneInfo | None = None, history: dict[date, dict[str, Any]] | None = None) -> dict[str, Any]:
    """The metric in each state the measurements define (sleep, stable awake rest, around movement) and by time of
    day, each against its own usual: the app's Baseline for the nightly value, the context layer's personal reference
    for the others. A state the server does not measure is listed as such, never filled in."""
    signal, d = metric.signal, metric.signal.decimals
    nightly = {day: v for day, v in nights(scores, signal, anchor - timedelta(days=WINDOW_DAYS), anchor) if v is not None}
    states, unavailable = [], []
    for state, label, key in STATE_SERIES.get(metric.key, ()):
        entry: dict[str, Any] = {"state": state, "label": label}
        if state == "sleep":
            value = nightly.get(anchor)
            baseline = app_baseline(scores if history is None else history, signal.layer1, anchor, d)
            call = baseline["call"]
            entry.update(value=rounded(value, d), units=signal.units, available=value is not None,
                         source="the night's score", usual=_shown_usual(baseline), week=baseline["week"],
                         long=baseline["long"], app_call=call["state"],
                         position=CALL_POSITION[call["state"]] if call["state"] != layer1.OFF
                         else f"{call['side']}_usual_band")
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
STILL_SHARE_MIN = 0.8              # and one at least this still (and not just after activity) as awake and still
AFTER_MOVEMENT_S = 1800            # within 30 minutes of the end of supported activity
SLOT_STATES = {"sleep": "during sleep", "still_awake": "while awake and still", "after_movement": "in the half hour "
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
            elif (_num(shares.get("stationary")) or 0.0) >= STILL_SHARE_MIN:
                state = "still_awake"
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


def activity_context(document: dict[str, Any] | None, scores: dict[date, dict[str, Any]] | None = None,
                     anchor: date | None = None) -> dict[str, Any]:
    """The day's activity level from wrist motion (the context layer) and, when the hosted day has it, the energy
    model's split of the day's calories (resting, active, workouts; minutes by intensity)."""
    out: dict[str, Any] = {"available": False, "reason": "no_context_document"}
    if document:
        values = {}
        for value in document.get("daily_values") or []:
            if isinstance(value, dict) and str(value.get("series_key", "")).startswith(("functional.", "coverage.")):
                values[value["series_key"]] = _num(value.get("value"))
        observed = values.get("coverage.motion_observed_s")
        out = {"available": True, "estimated": True,
               "motion_observed_h": rounded(observed / 3600.0, 1) if observed is not None else None,
               "locomotion_min_per_worn_hour": _per(values.get("functional.locomotion_s_per_worn_hour"), 60.0, 1),
               "bouts_per_worn_hour": rounded(values.get("functional.bouts_per_worn_hour"), 2),
               "median_bout_min": _per(values.get("functional.median_bout_s"), 60.0, 1),
               "note": "daily activity level from wrist motion (estimated); motion_observed_h is the time the strap "
                       "saw wrist motion data, not necessarily the time it was worn"}
    energy = energy_context(scores or {}, anchor) if anchor else None
    if energy:
        out["energy"] = energy
    return out


def energy_context(scores: dict[date, dict[str, Any]], day: date) -> dict[str, Any] | None:
    """The energy model's estimate of the day (the app's Calories value is its total) and its parts, with the
    median total of the person's previous measured days."""
    energy = (scores.get(day) or {}).get("energy")
    if not isinstance(energy, dict) or _num(energy.get("total_kcal")) is None:
        return None
    totals = [v for d, row in sorted(scores.items()) if d < day
              and (v := plausible(SIGNALS["calories"], (row or {}).get("total_kcal"))) is not None][-BASELINE_NIGHTS:]
    minutes = {k: rounded(_num(energy.get(f"{k}_min")), 0) for k in ("sedentary", "light", "moderate", "high")}
    out = {"day": day.isoformat(), "estimated": True,
           "total_kcal": rounded(_num(energy.get("total_kcal")), 0),
           "resting_kcal": rounded(_num(energy.get("resting_kcal")), 0),
           "active_kcal": rounded(_num(energy.get("active_kcal")), 0),
           "workout_kcal": rounded(_num(energy.get("workout_kcal")), 0),
           "workouts": energy.get("workouts"),
           "minutes_by_intensity": {k: v for k, v in minutes.items() if v is not None},
           "coverage_min": rounded(_num(energy.get("coverage_min")), 0),
           "gap_min": rounded(_num(energy.get("gap_min")), 0),
           "model_confidence": rounded(_num(energy.get("confidence")), 2),
           "note": "the energy model's estimate (resting + active energy), not a measurement; gap_min = minutes "
                   "without enough data, filled by the model"}
    if len(totals) >= 3:
        out["usual_total_kcal"] = {"median": rounded(median(totals), 0), "days": len(totals)}
    return out


# --------------------------------------------------------------------------- ElderNet gait (steps)


def _clock_of(epoch: int, zone: ZoneInfo) -> str:
    return datetime.fromtimestamp(epoch, zone).strftime("%H:%M")


def gait_context(rows: list[dict[str, Any]], day: date, zone: ZoneInfo) -> dict[str, Any]:
    """How the person walked on the day, read as the app's "How you walked" card reads it (gait.py: the windows
    starting inside the local day), and the walking of the days before from the stored day summaries."""
    if not rows:
        return {"available": False, "reason": "no_gait_data",
                "note": "no ElderNet gait for these days; say nothing about how the person walked"}
    start = int(datetime.combine(day, time(), zone).timestamp())
    end = int(datetime.combine(day + timedelta(days=1), time(), zone).timestamp())
    utc_days = {datetime.fromtimestamp(t, timezone.utc).date() for t in (start, end - 1)}
    today = [row for row in rows if row["day"] in utc_days]
    columns = [c for c in (gait.columns(row.get("windows")) for row in today) if c is not None]
    out: dict[str, Any] = {"available": True, "day": day.isoformat(), "estimated": True,
                           "model": sorted({str(row.get("model_version")) for row in today}) or None,
                           "note": "ElderNet's estimate of walking from wrist motion (a model, fine-tuned on older "
                                   "adults; it can miss some walking); not a step count"}
    if columns:
        r = gait.reading(columns, start, end)
        bands = dict(zip(("strolling", "steady", "brisk", "fast"), r.cadence_band_seconds))
        longest = sorted(r.bouts, key=lambda b: b.seconds, reverse=True)[:6]
        out.update(
            walking_min=rounded(r.walking_seconds / 60.0, 0), brisk_min=rounded(r.brisk_seconds / 60.0, 0),
            walks=len(r.bouts), walk_steps=rounded(r.steps, 0) if r.steps is not None else None,
            cadence_spm=rounded(r.cadence_spm, 0), typical_speed_mps=rounded(r.typical_speed_mps, 2),
            typical_speed_kmh=rounded(r.typical_speed_mps * 3.6, 1) if r.typical_speed_mps is not None else None,
            stride_m=rounded(r.stride_m, 2), regularity_pct=rounded(r.regularity * 100, 0) if r.regularity is not None
            else None,
            minutes_by_cadence={k: rounded(v / 60.0, 0) for k, v in bands.items()},
            longest_walks=[{"start_local": _clock_of(b.start, zone), "end_local": _clock_of(b.end, zone),
                            "minutes": rounded(b.seconds / 60.0, 0), "cadence_spm": rounded(b.cadence_spm, 0),
                            "speed_mps": rounded(b.speed_mps, 2)} for b in sorted(longest, key=lambda b: b.start)],
            assessed=r.assessed_windows > 0, source="the day's 10-second windows")
    elif today:  # windows too large to store: the UTC day's own summary
        summary = next(((row.get("gait") or {}) for row in today if isinstance(row.get("gait"), dict)), {})
        out.update(walking_min=rounded(sum((row.get("n_gait") or 0) * (row.get("hop_s") or 0) for row in today)
                                       / 60.0, 0),
                   cadence_spm=rounded(_num(summary.get("cadence_spm")), 0),
                   typical_speed_mps=rounded(_num(summary.get("speed_mps")), 2), source="the UTC day summary")
    else:
        out.update(available=False, reason="no_gait_data_that_day")
    earlier = [row for row in rows if row["day"] < min(utc_days) and row.get("n_gait") is not None]
    minutes = [(row.get("n_gait") or 0) * (row.get("hop_s") or 0) / 60.0 for row in earlier]
    cadences = [v for row in earlier if (v := _num((row.get("gait") or {}).get("cadence_spm"))) is not None]
    if len(minutes) >= 3:
        out["previous_days"] = {"days": len(minutes), "walking_min_median": rounded(median(minutes), 0),
                                "cadence_spm_median": rounded(median(cadences), 0) if cadences else None,
                                "note": "per UTC day, from the stored day summaries"}
    return out


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
