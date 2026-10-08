"""Next-night "rebound" observations (spec-02 section 4, docs/spec-02/CONTRACT.md 5.5).

Document-level ``rebound`` block, definition ``sleep-rebound-1``. DESCRIPTIVE ONLY: how the
night after a short or fragmented night compared with the person's own usual night, over the
history window the request carries. No causal claim ("because"), no probability, no forecast,
no composite score.

Inputs: ``history.days[].nights`` - the published snapshot's sleep entries of each earlier local
day (``asleep_min`` / ``awake_min`` as the snapshot published them; null stays null). The target
day itself is not in the history (the loader reads days strictly before it), so the newest pair
ends on the day before the target.

Rules (all reported in ``rules``; every threshold is a project default, not a clinical cutoff):

1. A day's night is its LONGEST published entry by ``end - start`` among entries not flagged
   ``is_nap`` (the scorer's primary-session rule; first on ties by start). It is valid when both
   ``asleep_min`` and ``awake_min`` are present and ``asleep_min + awake_min > 0``.
2. A pair is (night of day D, night of day D+1): consecutive calendar days, both valid, and the
   second night starts at or after the first one ends.
3. Personal reference of a pair: the median ``asleep_min`` / ``awake_min`` of every OTHER valid
   night in the window (leave-pair-out, so neither night of the pair scores against itself). A pair
   needs at least ``min_reference_nights`` other nights.
4. The first night is SHORT when ``asleep_min <= reference_asleep - short_below_reference_min``;
   FRAGMENTED when ``awake_min >= reference_awake + fragmented_above_reference_min``. A night can
   be both.
5. For each qualifying pair the next night's differences from the same reference are
   ``next_asleep - reference_asleep`` and ``next_awake - reference_awake`` (minutes). Each set
   reports the median and IQR (linear interpolation) once it has ``min_pairs`` pairs; below that
   only the pair count is reported (null values, never zero).

``personal_reference`` is the median over ALL valid nights in the window (what the person's usual
night looked like); the per-pair leave-pair-out references are what the differences use.
"""

from __future__ import annotations

import datetime as _dt
import statistics
from dataclasses import asdict, dataclass
from typing import Any, Sequence

import numpy

from .contract import HistoryDayIn, HistoryNightIn, SleepFeaturesRequest, json_finite

DEFINITION_VERSION = "sleep-rebound-1"


@dataclass(frozen=True)
class ReboundConfig:
    """sleep-rebound-1 rules (project defaults). Numeric only: the Swift decoder reads ``rules``
    as a ``[String: Double]`` map."""
    short_below_reference_min: float = 60.0
    fragmented_above_reference_min: float = 30.0
    min_reference_nights: int = 7
    min_pairs: int = 3

    def to_wire(self) -> dict[str, float]:
        return {k: float(v) for k, v in asdict(self).items()}


REBOUND_CONFIG = ReboundConfig()

NOTES = ("Descriptive next-night differences from your own usual night after short or fragmented "
         "nights in the history window. Not a cause, a prediction or a probability; nights are as "
         "the published snapshot measured them.")


@dataclass(frozen=True)
class _Night:
    day: str
    ordinal: int  # proleptic Gregorian ordinal of the local day
    start: int
    end: int
    asleep: float
    awake: float
    timezone: str | None


def _main_night(nights: Sequence[HistoryNightIn]) -> HistoryNightIn | None:
    candidates = [n for n in nights if not n.is_nap]
    if not candidates:
        return None
    return sorted(candidates, key=lambda n: (-(n.end - n.start), n.start))[0]


def _median(xs: Sequence[float]) -> float | None:
    return json_finite(float(statistics.median(xs))) if xs else None


def _summary(xs: Sequence[float], pairs: int, min_pairs: int) -> dict[str, Any]:
    if pairs < min_pairs or not xs:
        return {"median": None, "iqr": None, "segments": pairs}
    q25, q75 = numpy.percentile(numpy.asarray(xs, dtype=float), [25, 75])
    return {"median": _median(xs), "iqr": json_finite(float(q75 - q25)), "segments": pairs}


def _empty_set() -> dict[str, Any]:
    return {"pairs": 0,
            "next_night_asleep_diff_min": {"median": None, "iqr": None, "segments": 0},
            "next_night_awake_diff_min": {"median": None, "iqr": None, "segments": 0},
            "pair_days": []}


def compute(req: SleepFeaturesRequest, cfg: ReboundConfig = REBOUND_CONFIG) -> dict[str, Any]:
    """The document-level ``rebound`` block."""
    base: dict[str, Any] = {
        "definition_version": DEFINITION_VERSION,
        "history_revision_digest": req.context.history_revision_digest,
        "rules": cfg.to_wire(),
        "unit": "min",
        "notes": NOTES,
        "descriptive_only": True,
    }
    reasons: list[str] = []

    # One entry per day (a repeated day keeps its LAST occurrence, deterministically).
    by_day: dict[str, HistoryDayIn] = {}
    for d in req.history_days:
        if d.day in by_day:
            reasons.append("duplicate_history_day_resolved")
        by_day[d.day] = d

    nights: list[_Night] = []
    days_with_entries = 0
    invalid = 0
    for day in sorted(by_day):
        d = by_day[day]
        if not d.nights:
            continue
        days_with_entries += 1
        m = _main_night(d.nights)
        if m is None or m.asleep_min is None or m.awake_min is None or m.asleep_min + m.awake_min <= 0:
            invalid += 1
            continue
        try:
            ordinal = _dt.date.fromisoformat(day).toordinal()
        except ValueError:
            invalid += 1
            continue
        nights.append(_Night(day=day, ordinal=ordinal, start=m.start, end=m.end,
                             asleep=float(m.asleep_min), awake=float(m.awake_min), timezone=d.timezone))
    if invalid:
        reasons.append("history_nights_without_minutes_excluded")

    reference = {
        "median_asleep_min": _median([n.asleep for n in nights]),
        "median_awake_min": _median([n.awake for n in nights]),
        "nights": len(nights),
        "days_evaluated": len(by_day),
    }

    if days_with_entries == 0:
        return {**base, "status": "withheld",
                "reasons": sorted(set(reasons + ["history_nights_not_in_request"])),
                "personal_reference": reference, "after_short": _empty_set(),
                "after_fragmented": _empty_set(), "pairs_evaluated": 0}
    if len(nights) < cfg.min_reference_nights + 2:
        return {**base, "status": "withheld",
                "reasons": sorted(set(reasons + ["insufficient_reference_nights"])),
                "personal_reference": reference, "after_short": _empty_set(),
                "after_fragmented": _empty_set(), "pairs_evaluated": 0}

    short: dict[str, list] = {"asleep": [], "awake": [], "days": []}
    frag: dict[str, list] = {"asleep": [], "awake": [], "days": []}
    pairs_evaluated = 0
    tz_change = False
    for i in range(len(nights) - 1):
        a, b = nights[i], nights[i + 1]
        if b.ordinal != a.ordinal + 1 or b.start < a.end:
            continue
        others = [n for k, n in enumerate(nights) if k not in (i, i + 1)]
        if len(others) < cfg.min_reference_nights:
            continue
        pairs_evaluated += 1
        ref_asleep = statistics.median([n.asleep for n in others])
        ref_awake = statistics.median([n.awake for n in others])
        d_asleep = b.asleep - ref_asleep
        d_awake = b.awake - ref_awake
        is_short = a.asleep <= ref_asleep - cfg.short_below_reference_min
        is_frag = a.awake >= ref_awake + cfg.fragmented_above_reference_min
        if (is_short or is_frag) and a.timezone and b.timezone and a.timezone != b.timezone:
            tz_change = True
        for flag, bucket in ((is_short, short), (is_frag, frag)):
            if flag:
                bucket["asleep"].append(d_asleep)
                bucket["awake"].append(d_awake)
                bucket["days"].append([a.day, b.day])

    if pairs_evaluated == 0:
        reasons.append("no_consecutive_night_pairs")
    if tz_change:
        reasons.append("pair_spans_timezone_change")

    def build(bucket: dict[str, list], label: str) -> dict[str, Any]:
        n = len(bucket["days"])
        if n == 0:
            reasons.append(f"no_{label}_nights_observed")
        elif n < cfg.min_pairs:
            reasons.append(f"{label}_insufficient_pairs")
        return {"pairs": n,
                "next_night_asleep_diff_min": _summary(bucket["asleep"], n, cfg.min_pairs),
                "next_night_awake_diff_min": _summary(bucket["awake"], n, cfg.min_pairs),
                "pair_days": bucket["days"]}

    after_short = build(short, "short")
    after_frag = build(frag, "fragmented")
    any_summary = (after_short["pairs"] >= cfg.min_pairs or after_frag["pairs"] >= cfg.min_pairs)
    status = "available" if any_summary else "partial"
    return {**base, "status": status, "reasons": sorted(set(reasons)),
            "personal_reference": reference, "after_short": after_short,
            "after_fragmented": after_frag, "pairs_evaluated": pairs_evaluated}
