"""Canonical 30-second epoch timeline for sleep-phenotype modules.

Locked by docs/SLEEP_FEATURES_CONTRACT.md section 1. The grid:

* is anchored at the night's ``start`` with fixed 30 s epochs, half-open
  ``[start, end)``;
* resolves contradictory overlapping segments by LATER-START-WINS (the
  current resolver's rule) and counts the loser's overlapped seconds in
  ``overlap_seconds``;
* labels an epoch by MAJORITY coverage of a known stage over the epoch's own
  30 s (a strict tie between stages goes to the earlier covering segment; no
  stage reaches half -> ``uns``);
* never invents a label for missing/off-wrist/unscored spans (they stay
  ``uns``);
* keeps public DURATION metrics on exact segment intersections (partial
  first/last epochs keep their actual duration) while TRANSITION statistics
  use only fully-observed epochs and never cross an unresolved gap;
* reports coverage counters so downstream gates can publish ``partial``.

No module may build its own grid.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence

from .contract import NightIn, StageSegmentIn

EPOCH_S = 30

#: An interior stage-coverage gap longer than this stays ``uns`` and no
#: transition is counted across it (spec 4.1: "no unresolved internal gap over
#: 60 seconds" for the full-night continuity gate).
MAX_UNRESOLVED_GAP_S = 60


@dataclass(frozen=True)
class Timeline:
    """The canonical epoch grid for one night."""

    night: NightIn
    #: len == n_epochs, values in ("wake","light","deep","rem","uns")
    labels: tuple[str, ...]
    #: seconds of ANY resolved stage coverage per epoch (<= EPOCH_S)
    coverage_s: tuple[float, ...]
    #: epoch is fully observed (coverage_s >= EPOCH_S)
    fully_observed: tuple[bool, ...]
    #: interior (start, end) uncovered spans longer than MAX_UNRESOLVED_GAP_S
    unresolved_gaps: tuple[tuple[int, int], ...]
    #: exact per-stage seconds over [start, end): segment-intersection sums
    stage_seconds: dict[str, float]
    #: seconds lost to contradictory overlaps (last writer wins)
    overlap_seconds: float

    @property
    def n_epochs(self) -> int:
        return len(self.labels)

    @property
    def known_fraction(self) -> float:
        span = float(self.night.end - self.night.start)
        if span <= 0:
            return 0.0
        known = sum(v for k, v in self.stage_seconds.items() if k != "uns")
        return max(0.0, min(1.0, known / span))

    def first_epoch_index_of(self, stages: Sequence[str]) -> int | None:
        for i, label in enumerate(self.labels):
            if label in stages:
                return i
        return None

    def epoch_start(self, i: int) -> int:
        return self.night.start + i * EPOCH_S

    def epoch_end(self, i: int) -> int:
        return self.epoch_start(i) + EPOCH_S

    def stage_intervals(self, stage: str) -> list[tuple[int, int]]:
        """Half-open [start, end) runs of contiguous fully-observed epochs
        labelled ``stage`` (epoch-aligned by construction)."""
        out: list[tuple[int, int]] = []
        i = 0
        n = self.n_epochs
        while i < n:
            if self.labels[i] == stage and self.fully_observed[i]:
                j = i
                while j < n and self.labels[j] == stage and self.fully_observed[j]:
                    j += 1
                out.append((self.epoch_start(i), self.epoch_start(j)))
                i = j
            else:
                i += 1
        return out

    def gap_epoch_span(self, i: int) -> tuple[int, int] | None:
        """The unresolved-gap epoch span containing epoch ``i``, if any.

        A transition between adjacent epochs (i, i+1) must NOT be counted when
        a gap's span covers [i, i+1] (the pair straddles the gap)."""
        e_start, e_end = self.epoch_start(i), self.epoch_start(i + 1)
        for g0, g1 in self.unresolved_gaps:
            if g0 < e_end and e_start < g1:
                return (g0, g1)
        return None

    def seconds_between(self, lo: int, hi: int, stages: Sequence[str]) -> float:
        """Exact resolved seconds of ``stages`` inside [lo, hi) (intersection
        with resolved segments; partial edges keep their true duration)."""
        total = 0.0
        for stage in stages:
            for seg_lo, seg_hi in self.resolved_intervals_for(stage):
                s, e = max(seg_lo, lo), min(seg_hi, hi)
                if e > s:
                    total += float(e - s)
        return total

    def resolved_intervals_for(self, stage: str) -> tuple[tuple[int, int], ...]:
        return tuple(self._resolved.get(stage, ()))

    _resolved: dict[str, tuple[tuple[int, int], ...]] = field(default_factory=dict)


def _resolve_overlaps(stages: Sequence[StageSegmentIn]) -> tuple[dict[str, list[tuple[int, int]]], float]:
    """Later start wins; earlier segments are clipped against later ones.

    Returns per-stage NON-OVERLAPping interval lists plus the total seconds
    lost to contradictory overlaps.
    """
    # claimed: sorted list of (lo, hi) already owned by a LATER segment.
    claimed: list[tuple[int, int]] = []
    out: dict[str, list[tuple[int, int]]] = {}
    overlap_s = 0.0
    # Latest start first; within one start, later end first (stable, total).
    for seg in sorted(stages, key=lambda s: (-s.start, -s.end)):
        pieces: list[tuple[int, int]] = []
        lo, hi = seg.start, seg.end
        # subtract all already-claimed intervals
        intervals = [(lo, hi)]
        for c_lo, c_hi in claimed:
            nxt = []
            for s, e in intervals:
                if c_hi <= s or c_lo >= e:
                    nxt.append((s, e))
                    continue
                overlap_s += float(min(e, c_hi) - max(s, c_lo))
                if s < c_lo:
                    nxt.append((s, c_lo))
                if c_hi < e:
                    nxt.append((c_hi, e))
            intervals = nxt
        pieces = intervals
        claimed.append((seg.start, seg.end))
        out.setdefault(seg.stage, []).extend(pieces)
    for stage, lst in out.items():
        lst.sort()
        # merge touching pieces of the SAME stage
        merged: list[tuple[int, int]] = []
        for lo, hi in lst:
            if merged and lo <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
            else:
                merged.append((lo, hi))
        out[stage] = merged
    return out, overlap_s


def build_timeline(night: NightIn) -> Timeline:
    """Build the canonical grid for one night (pure, deterministic)."""
    span = night.end - night.start
    n_epochs = (span + EPOCH_S - 1) // EPOCH_S

    resolved, overlap_s = _resolve_overlaps(night.stages)

    # clip every resolved piece to the night span and collect merged coverage
    clipped: dict[str, list[tuple[int, int]]] = {}
    for stage, pieces in resolved.items():
        lst = []
        for lo, hi in pieces:
            s, e = max(lo, night.start), min(hi, night.end)
            if e > s:
                lst.append((s, e))
        clipped[stage] = lst

    stage_seconds = {s: 0.0 for s in ("wake", "light", "deep", "rem", "uns")}
    for stage, pieces in clipped.items():
        stage_seconds[stage] = float(sum(hi - lo for lo, hi in pieces))

    # epoch labelling: majority over the epoch's own 30 s
    labels: list[str] = []
    coverage: list[float] = []
    fully: list[bool] = []
    for e in range(n_epochs):
        e_start = night.start + e * EPOCH_S
        e_end = e_start + EPOCH_S
        per_stage: dict[str, float] = {}
        order: list[str] = []  # first-appearance order (clipped is dict-ordered;
        # rebuild deterministically by earliest interval start)
        events = []
        for stage, pieces in clipped.items():
            for lo, hi in pieces:
                s, t = max(lo, e_start), min(hi, e_end)
                if t > s:
                    per_stage[stage] = per_stage.get(stage, 0.0) + float(t - s)
                    events.append((lo, stage))
        total = sum(per_stage.values())
        coverage.append(min(total, float(EPOCH_S)))
        fully.append(total >= float(EPOCH_S))
        if not per_stage:
            labels.append("uns")
            continue
        first_seen = {}
        for lo, stage in sorted(events):
            first_seen.setdefault(stage, lo)
        best_stage = None
        best_cov = -1.0
        for stage, cov in per_stage.items():
            if (cov > best_cov + 1e-9
                    or (abs(cov - best_cov) <= 1e-9
                        and best_stage is not None
                        and first_seen[stage] < first_seen[best_stage])):
                best_stage, best_cov = stage, cov
        half = EPOCH_S / 2.0
        if best_cov > half + 1e-9:
            labels.append(best_stage)
        elif abs(best_cov - half) <= 1e-9 and len(per_stage) == 1:
            # exactly half covered by a single stage: no majority -> uns
            labels.append("uns")
        elif abs(best_cov - half) <= 1e-9 and best_stage is not None:
            # strict tie between stages: the earlier covering segment wins
            labels.append(best_stage)
        else:
            labels.append("uns")

    # interior unresolved gaps: holes in merged coverage longer than the gate
    merged: list[tuple[int, int]] = []
    for pieces in clipped.values():
        merged.extend(pieces)
    merged.sort()
    coalesced: list[tuple[int, int]] = []
    for lo, hi in merged:
        if coalesced and lo <= coalesced[-1][1]:
            coalesced[-1] = (coalesced[-1][0], max(coalesced[-1][1], hi))
        else:
            coalesced.append((lo, hi))
    gaps: list[tuple[int, int]] = []
    prev_end = night.start
    for lo, hi in coalesced:
        if lo - prev_end > MAX_UNRESOLVED_GAP_S:
            gaps.append((prev_end, lo))
        prev_end = max(prev_end, hi)
    if night.end - prev_end > MAX_UNRESOLVED_GAP_S:
        gaps.append((prev_end, night.end))

    return Timeline(
        night=night,
        labels=tuple(labels),
        coverage_s=tuple(coverage),
        fully_observed=tuple(fully),
        unresolved_gaps=tuple(gaps),
        stage_seconds=stage_seconds,
        overlap_seconds=overlap_s,
        _resolved={stage: tuple(pieces) for stage, pieces in clipped.items()},
    )


def yasa_labels(timeline: Timeline) -> list[str]:
    """Labels in YASA's vocabulary (WAKE/LIGHT/DEEP/REM/UNS), one per 30 s epoch."""
    return [label.upper() for label in timeline.labels]


def actual_sleep_onset(timeline: Timeline) -> int | None:
    """First sleep epoch (light/deep/rem) start, unix seconds, or None.

    This is the canonical ACTUAL sleep onset (spec 2.1): derived from the
    staged timeline, never ``session.start``."""
    i = timeline.first_epoch_index_of(("light", "deep", "rem"))
    return timeline.epoch_start(i) if i is not None else None


def final_sleep_end(timeline: Timeline) -> int | None:
    """End of the last sleep epoch (light/deep/rem), unix seconds, or None."""
    for i in range(timeline.n_epochs - 1, -1, -1):
        if timeline.labels[i] in ("light", "deep", "rem"):
            return timeline.epoch_end(i)
    return None
