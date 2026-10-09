"""Rule `exercise-session-1` (docs/context-watchdog/EXERCISE_SESSION.md), ported from the shared reference
`contracts/reference/exercise_session_1.py` and pinned to its fixture `contracts/reference/exercise-session-1.json`
(tests/test_exercise_session.py). The algorithm is the reference's (the density scan uses prefix sums so a long
period stays linear). The one extension: the rest reference may be a function of the period's first minute, because
the service resolves it per period (the nightly resting heart rate of the nights before, else the person's still
minutes before the period), where the fixture passes one number per case.

A strap sees resistance training as mostly still. A session is a period OPENED BY MOVEMENT (heart rate never opens
one) that keeps its still minutes, followed by a recovery phase; neither belongs in a rest or sleep reference.
"""

from __future__ import annotations

import statistics
from typing import Callable, Sequence

RULE = "exercise-session-1"
MERGE_GAP_MIN = 10
ANCHOR_MIN = 20
SPAN_MIN = 10
MIN_EVIDENCE_IN_SPAN = 3
MIN_STRONG = 2
LOAD_DELTA_BPM = 25
MIN_LOAD_MIN = 8
MIN_DURATION_MIN = 12
RETURN_DELTA_BPM = 10
RETURN_RUN_MIN = 5
RECOVERY_CAP = (30, 120)
PRE_WINDOW = (45, 10)
DEFAULT_REST_BPM = 70.0

Rest = float | Callable[[int], float]


def anchored(strong, weak) -> list[bool]:
  """Counted evidence: strong minutes, and weak minutes within ANCHOR_MIN minutes of a strong one, so weak movement
  far from any strong minute (a fidgety afternoon) never forms or stretches a period."""
  n = len(strong)
  strong_idx = [i for i in range(n) if strong[i]]
  out = [False] * n
  j = 0
  for i in range(n):
    if strong[i]:
      out[i] = True
    elif weak[i]:
      while j < len(strong_idx) and strong_idx[j] < i - ANCHOR_MIN:
        j += 1
      out[i] = j < len(strong_idx) and strong_idx[j] <= i + ANCHOR_MIN
  return out


def periods(evidence: Sequence[bool]) -> list[list[int]]:
  """Active periods: evidence minutes merged while the gap is at most MERGE_GAP_MIN minutes."""
  out: list[list[int]] = []
  for i, e in enumerate(evidence):
    if not e:
      continue
    if out and i - out[-1][1] <= MERGE_GAP_MIN:
      out[-1][1] = i
    else:
      out.append([i, i])
  return out


def _rest_at(rest: Rest, a: int) -> float:
  return float(rest(a)) if callable(rest) else float(rest)


def qualifies(a: int, b: int, hr, strong, weak, rest: float, counted: Sequence[bool] | None = None) -> bool:
  # Prefix sums over the period: the reference's window scan, O(length) instead of O(length × span).
  counted = counted if counted is not None else anchored(strong, weak)
  ev = [bool(counted[i]) for i in range(a, b + 1)]
  cs = [0]
  for e in ev:
    cs.append(cs[-1] + int(e))
  n = b - a + 1
  dense = any(cs[min(s + SPAN_MIN, n)] - cs[s] >= MIN_EVIDENCE_IN_SPAN for s in range(n))
  n_strong = sum(1 for i in range(a, b + 1) if strong[i])
  load = sum(1 for i in range(a, b + 1) if hr[i] is not None and hr[i] >= rest + LOAD_DELTA_BPM)
  duration = b - a + 1
  return dense and n_strong >= MIN_STRONG and load >= MIN_LOAD_MIN and duration >= MIN_DURATION_MIN


def pre_reference(a: int, hr, rest: float, busy: set[int], fallback: float | None) -> float:
  """Median HR 45..10 minutes before `a`, skipping minutes inside an earlier session or its recovery."""
  lo, hi = max(0, a - PRE_WINDOW[0]), max(0, a - PRE_WINDOW[1])
  vals = [hr[i] for i in range(lo, hi) if hr[i] is not None and i not in busy]
  if vals:
    return statistics.median(vals)
  return fallback if fallback is not None else rest


def session_spans(hr, strong, weak, rest: Rest) -> list[dict]:
  """Completed sessions over a contiguous minute grid, as minute indices: {a, b, end, pre, rest} where a/b are the
  first/last evidence minute and `end` the first minute that is no longer recovery (exclusive)."""
  n = len(hr)
  ev = anchored(strong, weak)
  found = []
  for a, b in periods(ev):
    r = _rest_at(rest, a)
    if qualifies(a, b, hr, strong, weak, r, ev):
      found.append((a, b, r))
  out = []
  busy: set[int] = set()
  previous_pre = None
  for k, (a, b, r) in enumerate(found):
    pre = pre_reference(a, hr, r, busy, previous_pre)
    previous_pre = pre
    duration = b - a + 1
    cap = min(max(duration, RECOVERY_CAP[0]), RECOVERY_CAP[1])
    limit = min(n, b + 1 + cap)
    if k + 1 < len(found):
      limit = min(limit, found[k + 1][0])
    end = limit
    run = 0
    for i in range(b + 1, limit):
      if hr[i] is not None and hr[i] <= pre + RETURN_DELTA_BPM:
        run += 1
        if run == RETURN_RUN_MIN:
          end = i - RETURN_RUN_MIN + 1
          break
      else:
        run = 0
    busy.update(range(a, end))
    out.append({"a": a, "b": b, "end": end, "pre": float(pre), "rest": r})
  return out


def sessions(t0: int, hr, strong, weak, rest: Rest) -> list[dict]:
  """The reference's output: [{start, end, recovery_end, pre_reference}] in unix seconds."""
  return [{"start": t0 + s["a"] * 60, "end": t0 + s["b"] * 60, "recovery_end": t0 + s["end"] * 60,
           "pre_reference": round(float(s["pre"]), 3)} for s in session_spans(hr, strong, weak, rest)]
