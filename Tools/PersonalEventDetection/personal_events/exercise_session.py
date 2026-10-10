"""Rule `exercise-session-2` over stored activity-context intervals, as the phone's Layer 1 materializer runs it.

Ported from Packages/StrandAnalytics/Sources/StrandAnalytics/ExerciseSession.swift: `ExerciseSessionRule.evidence(of:)`,
`minutes(fromIntervals:)` and the batch path of `sessions(minutes:restReference:)` (no `nowUnix`, so no open sessions).
The rule itself is pinned to contracts/reference/exercise-session-2.json (tests/test_exercise_session.py); the
interval evidence is pinned through the Layer 1 mirror cases (tests/test_layer1_context.py).
"""
from __future__ import annotations

import dataclasses

RULE = "exercise-session-2"
MERGE_GAP_MIN = 10
ANCHOR_MIN = 20
SPAN_MIN = 10
MIN_EVIDENCE_IN_SPAN = 3
MIN_STRONG = 2
LOAD_DELTA_BPM = 25.0
MIN_LOAD_MIN = 8
MIN_DURATION_MIN = 12
RETURN_DELTA_BPM = 10.0
RETURN_RUN_MIN = 5
RECOVERY_CAP = (30, 120)
PRE_WINDOW = (45, 10)
MIN_CONFIRM_STRONG = 15
INHERIT_MIN = 30

STRONG_INTENSITY = 0.48
WEAK_INTENSITY = 0.40
STRONG_LOCOMOTION = frozenset({"walking", "brisk_walking", "running"})
STRONG_CLASSES = frozenset({"brisk_walking", "running", "cycling", "vigorous_activity"})
WEAK_CLASSES = frozenset({"light_activity"})
MIN_COVER_S = 20


@dataclasses.dataclass(frozen=True)
class Session:
  start: int                    # first evidence minute (unix seconds)
  end: int                      # last evidence minute
  recovery_end: int             # first minute no longer in recovery (end + 60 when unconfirmed)
  pre_reference: float
  confirmed: bool
  confirmed_at: int | None


def evidence(r) -> tuple[bool, bool]:
  """ExerciseSessionRule.evidence(of:): (strong, weak) from one interval; off-wrist and asleep are never evidence."""
  if r.wear_state == "off_wrist" or r.sleep_state == "asleep":
    return False, False
  strong = ((r.locomotion or "") in STRONG_LOCOMOTION or r.activity_class in STRONG_CLASSES
            or r.arm_behavior == "exercise_motion"
            or (r.intensity is not None and r.intensity >= STRONG_INTENSITY))
  weak = r.activity_class in WEAK_CLASSES or (r.intensity is not None and r.intensity >= WEAK_INTENSITY)
  return strong, weak


def minutes_from_intervals(rows):
  """ExerciseSessionRule.minutes(fromIntervals:): (t0, hr, strong, weak) over every minute from the first interval's
  minute to the last end. A minute is strong (weak) when strong (any evidence) intervals cover >= 20 s of it; HR is the
  sample-weighted mean of the covering intervals."""
  rows = sorted(rows, key=lambda x: x.start)
  if not rows:
    return 0, [], [], []
  start = rows[0].start - rows[0].start % 60
  last = max(r.end for r in rows)
  strong_s, evid_s, hr_w, hr_sum = {}, {}, {}, {}
  for r in rows:
    if not r.end > r.start:
      continue
    ev_strong, ev_weak = evidence(r)
    rate = float(r.hr_samples) / float(r.end - r.start)
    t = r.start - r.start % 60
    while t < r.end:
      overlap = min(r.end, t + 60) - max(r.start, t)
      if overlap > 0:
        if ev_strong:
          strong_s[t] = strong_s.get(t, 0) + overlap
        if ev_strong or ev_weak:
          evid_s[t] = evid_s.get(t, 0) + overlap
        m = r.hr_mean
        if m is not None and m == m and abs(m) != float("inf") and r.hr_samples > 0 and r.wear_state != "off_wrist":
          w = rate * float(overlap)
          hr_w[t] = hr_w.get(t, 0.0) + w
          hr_sum[t] = hr_sum.get(t, 0.0) + m * w
      t += 60
  hr, strong, weak = [], [], []
  t = start
  while t < last:
    hr.append(hr_sum[t] / hr_w[t] if hr_w.get(t, 0.0) > 0 else None)
    s = strong_s.get(t, 0) >= MIN_COVER_S
    strong.append(s)
    weak.append(not s and evid_s.get(t, 0) >= MIN_COVER_S)
    t += 60
  return start, hr, strong, weak


def _median(xs):
  if not xs:
    return None
  s = sorted(xs)
  n = len(s)
  return s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2


def sessions(t0, hr, strong, weak, rest) -> list:
  """Completed sessions over a contiguous minute grid (the Swift batch path)."""
  n = len(hr)
  if n == 0:
    return []
  strong_idx = [i for i in range(n) if strong[i]]
  counted = [False] * n
  j = 0
  for i in range(n):
    if strong[i]:
      counted[i] = True
      continue
    if not weak[i]:
      continue
    while j < len(strong_idx) and strong_idx[j] < i - ANCHOR_MIN:
      j += 1
    counted[i] = j < len(strong_idx) and strong_idx[j] <= i + ANCHOR_MIN
  periods = []
  for i in range(n):
    if not counted[i]:
      continue
    if periods and i - periods[-1][1] <= MERGE_GAP_MIN:
      periods[-1][1] = i
    else:
      periods.append([i, i])
  found = []
  for a, b in periods:
    dense = any(sum(1 for k in range(s, min(s + SPAN_MIN, b + 1)) if counted[k]) >= MIN_EVIDENCE_IN_SPAN
                for s in range(a, b + 1))
    n_strong = sum(1 for k in range(a, b + 1) if strong[k])
    load = sum(1 for k in range(a, b + 1) if (hr[k] if hr[k] is not None else 0) >= rest + LOAD_DELTA_BPM)
    if not (dense and n_strong >= MIN_STRONG and load >= MIN_LOAD_MIN):
      continue
    if b - a + 1 < MIN_DURATION_MIN:
      continue
    found.append((a, b))
  out = []
  busy = set()
  previous_pre = None
  last_confirmed_end = None
  for k, (a, b) in enumerate(found):
    lo, hi = max(0, a - PRE_WINDOW[0]), max(0, a - PRE_WINDOW[1])
    pre_vals = [hr[i] for i in range(lo, hi) if i not in busy and hr[i] is not None]
    pre = _median(pre_vals)
    if pre is None:
      pre = previous_pre if previous_pre is not None else rest
    previous_pre = pre
    confirmed_at = None
    if last_confirmed_end is not None and a - last_confirmed_end <= INHERIT_MIN:
      confirmed_at = a
    else:
      count = 0
      for i in range(a, b + 1):
        if strong[i]:
          count += 1
          if count == MIN_CONFIRM_STRONG:
            confirmed_at = i
            break
    if confirmed_at is not None:
      last_confirmed_end = b
    if confirmed_at is None:
      end = b + 1
      busy.update(range(a, b + 1))
    else:
      duration = b - a + 1
      cap = min(max(duration, RECOVERY_CAP[0]), RECOVERY_CAP[1])
      limit = min(n, b + 1 + cap)
      if k + 1 < len(found):
        limit = min(limit, found[k + 1][0])
      end = limit
      run = 0
      for i in range(b + 1, max(b + 1, limit)):
        h = hr[i]
        if h is not None and h <= pre + RETURN_DELTA_BPM:
          run += 1
          if run == RETURN_RUN_MIN:
            end = i - RETURN_RUN_MIN + 1
            break
        else:
          run = 0
      busy.update(range(a, end))
    out.append(Session(t0 + a * 60, t0 + b * 60, t0 + end * 60, float(pre), confirmed_at is not None,
                       None if confirmed_at is None else t0 + confirmed_at * 60))
  return out


def from_intervals(rows, rest) -> list:
  t0, hr, strong, weak = minutes_from_intervals(rows)
  return sessions(t0, hr, strong, weak, rest)
