"""Transition (multi-label event) targets from timestamped label changes (INERTIA1.md §5, Agent C rules).

Target per window: ``int8 [8]`` over the transition class order, ``1`` event present, ``0`` absent,
``-1`` MASK. ``none`` is not an output: a negative window is all-8-zero.

Per run (one continuous clock), the labelled samples are run-length encoded into segments; each segment
gets the crosswalk's coarse state (sit/stand/lie/walk/run/sleep/other, ``None`` = null/unlabelled).
Consecutive segments with the same non-``other`` state are merged (PAMAP2 standing -> ironing is not a
change). Between consecutive labelled segments A, B a **boundary** is

* an *event boundary* when the dataset rule allows it (``direct_switch``: A and B touch or are separated
  by a null of <= ``max_null_s``; ``null_gap``: A and B are separated by a null gap of <= ``max_null_s``),
  the state pair is in ``event_pairs`` (and ``allowed_pairs`` if given). Each event gets an interval:
  ``direct_switch`` -> switch time + ``event_intervals_s``; ``null_gap`` -> the gap itself;
* otherwise an *unknown boundary* spanning the change (or the whole null in between).
Run edges are unknown boundaries too.

Window ``[w0, w1]`` (event-presence semantics):
* MASK if any unknown boundary span meets ``[w0 - guard, w1 + guard]``, or an event boundary's span meets
  that range without lying inside ``[w0 + 1, w1 - 1]``;
* positive (1 for its events, 0 for the rest) if >= 1 event boundary lies inside;
* negative (all 0) only if no boundary meets ``[w0 - interior, w1 + interior]`` and every label covering
  the window has a transition row ``none`` used for training;
* else MASK.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import HEAD_CLASS_ORDERS

EVENTS: Tuple[str, ...] = HEAD_CLASS_ORDERS["transition"]
N_EVENTS = len(EVENTS)


@dataclass
class Boundary:
    lo: float                    # span start (s)
    hi: float                    # span end (s)
    events: Tuple[str, ...]      # () for unknown boundaries
    t_ref: float                 # reference time for timing evaluation (event interval midpoint)
    pair: Tuple[Optional[str], Optional[str]]


@dataclass
class LabelSegment:
    t0: float
    t1: float
    code: int
    state: Optional[str]


def label_segments(t: np.ndarray, codes: np.ndarray, fs: float, states: Sequence[Optional[str]]) -> List[LabelSegment]:
    """Run-length segments of one run; ``t1`` = last sample time + 1/fs."""
    if len(t) == 0:
        return []
    chg = np.flatnonzero(codes[1:] != codes[:-1]) + 1
    starts, ends = np.r_[0, chg], np.r_[chg, len(codes)]
    return [LabelSegment(float(t[a]), float(t[b - 1]) + 1.0 / fs, int(codes[a]), states[int(codes[a])])
            for a, b in zip(starts, ends)]


def _merge(segs: List[LabelSegment]) -> List[List[LabelSegment]]:
    """Group consecutive segments with the same state that is not None/'other'."""
    groups: List[List[LabelSegment]] = []
    for s in segs:
        if groups and s.state is not None and s.state != "other" and groups[-1][-1].state == s.state:
            groups[-1].append(s)
        else:
            groups.append([s])
    return groups


def derive_boundaries(segs: List[LabelSegment], rule: Mapping, event_pairs: Mapping[Tuple[str, str], List[str]],
                      window_s: int) -> List[Boundary]:
    mode = rule.get("mode", "mask")
    positives_ok = mode in ("direct_switch", "null_gap") and window_s in rule.get("window_s_only", [window_s])
    allowed = {tuple(p) for p in rule.get("allowed_pairs", [])} or None
    max_null = float(rule.get("max_null_s", 0.0))
    intervals = rule.get("event_intervals_s", {})
    groups = _merge(segs)
    out: List[Boundary] = []
    if not groups:
        return out
    out.append(Boundary(groups[0][0].t0, groups[0][0].t0, (), groups[0][0].t0, (None, None)))   # run start
    i = 0
    while i < len(groups) - 1:
        a = groups[i]
        if a[0].state is None:            # leading null: an unlabelled span, never a negative or event
            out.append(Boundary(a[0].t0, a[-1].t1, (), 0.5 * (a[0].t0 + a[-1].t1), (None, None)))
            i += 1
            continue
        j = i + 1
        null_dur = 0.0
        if groups[j][0].state is None:          # one null group between two labelled groups
            null_dur = groups[j][-1].t1 - groups[j][0].t0
            j += 1
        if j >= len(groups):
            out.append(Boundary(a[-1].t1, groups[-1][-1].t1, (), a[-1].t1, (a[0].state, None)))
            break
        b = groups[j]
        sa, sb = a[0].state, b[0].state
        lo, hi = a[-1].t1, b[0].t0
        events = tuple(event_pairs.get((sa, sb), ())) if sb is not None else ()
        ok = bool(events) and positives_ok and (allowed is None or (sa, sb) in allowed)
        if mode == "direct_switch":
            ok = ok and null_dur <= max_null
        elif mode == "null_gap":
            ok = ok and 0.0 < null_dur <= max_null
        if ok and mode == "direct_switch":
            s = 0.5 * (lo + hi)
            spans = [intervals.get(e, intervals.get("default", [-2.0, 2.0])) for e in events]
            elo, ehi = s + min(x[0] for x in spans), s + max(x[1] for x in spans)
            ref = s + float(np.mean([0.5 * (x[0] + x[1]) for x in spans]))
            out.append(Boundary(min(elo, lo), max(ehi, hi), events, ref, (sa, sb)))
        elif ok:
            out.append(Boundary(lo, hi, events, 0.5 * (lo + hi), (sa, sb)))
        else:
            out.append(Boundary(lo, hi, (), 0.5 * (lo + hi), (sa, sb)))
        i = j
    last = groups[-1][-1]
    out.append(Boundary(last.t1, last.t1, (), last.t1, (None, None)))                            # run end
    return out


def window_targets(w0: np.ndarray, w1: np.ndarray, boundaries: List[Boundary], segs: List[LabelSegment],
                   none_ok: np.ndarray, guard_s: float = 3.0, interior_s: float = 5.0,
                   edge_s: float = 1.0) -> np.ndarray:
    """int8 [W, 8] targets for windows of one run (see module docstring)."""
    W = len(w0)
    out = np.full((W, N_EVENTS), -1, np.int8)
    if W == 0:
        return out
    lo = np.array([b.lo for b in boundaries]) if boundaries else np.zeros(0)
    hi = np.array([b.hi for b in boundaries]) if boundaries else np.zeros(0)
    is_event = np.array([bool(b.events) for b in boundaries], bool)
    w0c, w1c = w0[:, None], w1[:, None]
    meets_guard = (hi[None, :] >= w0c - guard_s) & (lo[None, :] <= w1c + guard_s)
    inside = (lo[None, :] >= w0c + edge_s) & (hi[None, :] <= w1c - edge_s)
    meets_interior = (hi[None, :] >= w0c - interior_s) & (lo[None, :] <= w1c + interior_s)
    bad = (meets_guard & ~is_event[None, :]).any(axis=1) | (meets_guard & is_event[None, :] & ~inside).any(axis=1)
    pos = (inside & is_event[None, :])
    has_pos = pos.any(axis=1) & ~bad
    ev_index = {e: k for k, e in enumerate(EVENTS)}
    for w in np.flatnonzero(has_pos):
        row = np.zeros(N_EVENTS, np.int8)
        for bi in np.flatnonzero(pos[w]):
            for e in boundaries[bi].events:
                row[ev_index[e]] = 1
        out[w] = row
    # negatives: no boundary within the interior margin and every covering label allows 'none'
    seg_t0 = np.array([s.t0 for s in segs])
    seg_t1 = np.array([s.t1 for s in segs])
    seg_ok = np.array([bool(none_ok[s.code]) and s.state is not None for s in segs], bool)
    cover = (seg_t1[None, :] > w0c) & (seg_t0[None, :] < w1c)
    all_ok = ~(cover & ~seg_ok[None, :]).any(axis=1) & cover.any(axis=1)
    neg = ~meets_interior.any(axis=1) & all_ok & ~has_pos
    out[neg] = 0
    return out


def timing_events(boundaries: List[Boundary]) -> List[Dict]:
    """Reference events for event-level evaluation: one entry per (event boundary, event type)."""
    return [{"type": e, "t": float(b.t_ref), "lo": float(b.lo), "hi": float(b.hi), "pair": list(b.pair)}
            for b in boundaries for e in b.events]


def masked_intervals(boundaries: List[Boundary], guard_s: float = 3.0) -> List[Tuple[float, float]]:
    """Unknown-boundary spans (+- guard): event predictions inside are neither TP nor FP."""
    return [(float(b.lo - guard_s), float(b.hi + guard_s)) for b in boundaries if not b.events]


__all__ = ["EVENTS", "N_EVENTS", "Boundary", "LabelSegment", "label_segments", "derive_boundaries",
           "window_targets", "timing_events", "masked_intervals"]
