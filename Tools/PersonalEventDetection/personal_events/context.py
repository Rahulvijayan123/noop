"""Per-minute measurement context (docs/PHENOTYPE_SIGNATURES.md, section 2)."""
from __future__ import annotations

import dataclasses

import numpy as np

from .timeline import ACTIVITY_CLASSES, POSTURES, Timeline

CONTEXTS = ("asleep", "still_supine", "still_seated", "still_upright", "still_unknown", "walking", "active",
            "recovery", "off", "unknown")
C = {name: i for i, name in enumerate(CONTEXTS)}
STILL = tuple(C[c] for c in ("still_supine", "still_seated", "still_upright", "still_unknown"))
BANDS = ((0, 6), (6, 12), (12, 18), (18, 24))
# Report grouping (signature-report-1 context_at_onset keys). Recovery is still posture after exertion.
GROUPS = {"asleep": ("asleep",), "still": ("still_supine", "still_seated", "still_upright", "still_unknown", "recovery"),
          "walking": ("walking",), "active": ("active",), "unknown": ("off", "unknown")}

STILL_MOTION_G = 0.05
ACTIVE_MOTION_G = 0.15
WALK_STEPS = 20
RECOVERY_AFTER_WALKING_MIN = 10
RECOVERY_AFTER_ACTIVE_MIN = 30
RECOVERY_SETTLE_MIN = 2
EXERTION_HORIZON_MIN = 24 * 60

_A = {name: i for i, name in enumerate(ACTIVITY_CLASSES)}
_P = {name: i for i, name in enumerate(POSTURES)}
_CLASS_CONTEXT = {"walking": "walking", "brisk_walking": "walking", "running": "active", "cycling": "active",
                  "vigorous_activity": "active", "light_activity": "active", "sitting": "still_seated",
                  "sitting_desk": "still_seated", "lying_down": "still_supine", "standing": "still_upright",
                  "sleeping": "asleep", "off_wrist": "off"}
_POSTURE_CONTEXT = {"recumbent": "still_supine", "seated_likely": "still_seated",
                    "upright_stationary": "still_upright"}


@dataclasses.dataclass
class Context:
  code: np.ndarray                     # (N,) int index into CONTEXTS
  minutes_since_exertion: np.ndarray   # (N,) float, NaN when no exertion in the previous 24 h of the timeline
  band: np.ndarray                     # (N,) int 0..3 (00-06, 06-12, 12-18, 18-24 local)

  def name(self, i):
    return CONTEXTS[int(self.code[i])]


def group_of(code: int) -> str:
  name = CONTEXTS[int(code)]
  return next(g for g, members in GROUPS.items() if name in members)


def classify(tl: Timeline) -> Context:
  n = len(tl)
  act = tl["activity"]; posture = tl["posture"]
  code = np.full(n, C["unknown"], np.int64)

  # 1. Sensor fallback (minutes without an activity class).
  steps = tl["steps"]; motion = tl["motion"]
  walking = np.isfinite(steps) & (steps >= WALK_STEPS)
  active = ~walking & np.isfinite(motion) & (motion >= ACTIVE_MOTION_G)
  still = ~walking & ~active & np.isfinite(motion) & (motion < STILL_MOTION_G) & (~np.isfinite(steps) | (steps == 0))
  code[still] = C["still_unknown"]; code[walking] = C["walking"]; code[active] = C["active"]

  # 2. Activity classifier where it has a class (unknown class -> keep the sensor rule).
  has = (act >= 0) & (act != _A["unknown"])
  for cls, ctx in _CLASS_CONTEXT.items():
    code[has & (act == _A[cls])] = C[ctx]
  for cls in ("stationary", "fidgeting"):
    sel = has & (act == _A[cls])
    code[sel] = C["still_unknown"]
    for p, ctx in _POSTURE_CONTEXT.items():
      code[sel & (posture == _P[p])] = C[ctx]

  # 3. Sleep overrides wake classes; 4. off-wrist / no usable HR overrides everything.
  asleep = (tl["asleep"] == 1) | tl["activity_asleep"]
  code[asleep & (code != C["off"])] = C["asleep"]
  off = tl["wrist_off"] | (code == C["off"])
  code[off] = C["off"]
  code[~off & ~tl["wear"]] = C["unknown"]

  code = _recovery(code)
  return Context(code=code, minutes_since_exertion=_since_exertion(code),
                 band=np.minimum((tl["local_hour"] // 6).astype(np.int64), 3))


def _recovery(code):
  """Still minutes shortly after exertion are recovery, not rest (anomaly service's steady-state rule on bouts:
  30 min after a vigorous bout of >= 3 active minutes, 10 min after a walking bout of >= 2 exertion minutes,
  a 2-minute settle after a single exertion minute; 1-minute gaps inside a bout are bridged)."""
  out = code.copy()
  n = len(out)
  exert = (out == C["walking"]) | (out == C["active"])
  idx = np.flatnonzero(exert)
  if not len(idx):
    return out
  still = np.isin(out, STILL)
  # Bouts: runs of exertion minutes allowing single-minute gaps.
  breaks = np.flatnonzero(np.diff(idx) > 2)
  starts = np.r_[idx[0], idx[breaks + 1]]; ends = np.r_[idx[breaks], idx[-1]]
  for s, e in zip(starts, ends):
    seg = out[s:e + 1]
    n_active = int(np.sum(seg == C["active"])); length = int(np.sum((seg == C["walking"]) | (seg == C["active"])))
    hold = RECOVERY_AFTER_ACTIVE_MIN if n_active >= 3 else (RECOVERY_AFTER_WALKING_MIN if length >= 2 else RECOVERY_SETTLE_MIN)
    stop = min(n, e + 1 + hold)
    nxt = np.flatnonzero(exert[e + 1:stop])
    if len(nxt):
      stop = e + 1 + nxt[0]
    window = slice(e + 1, stop)
    out[window] = np.where(still[window], C["recovery"], out[window])
  return out


def _since_exertion(code):
  n = len(code)
  exert = (code == C["walking"]) | (code == C["active"])
  pos = np.where(exert, np.arange(n), -1)
  last = np.maximum.accumulate(pos)
  since = np.arange(n) - last
  return np.where((last >= 0) & (since <= EXERTION_HORIZON_MIN), since.astype(np.float64), np.nan)


PRE_WINDOW_MIN = 15
_GROUP_NAMES = tuple(GROUPS)
GROUP_OF_CODE = np.array([_GROUP_NAMES.index(group_of(c)) for c in range(len(CONTEXTS))], dtype=np.int64)


@dataclasses.dataclass
class PreWindow:
  """Context composition of the window [i - u - 15, i - u) before every anchor minute i. The window excludes the
  onset uncertainty u: a late log must not let the event's own movement decide its context."""
  dominant: np.ndarray     # (N,) dominant context code, -1 where the window leaves the timeline
  share: np.ndarray        # (N,) share of the window in the dominant context
  last_group: np.ndarray   # (N,) report group (asleep/still/walking/active/unknown) of the window's last minute


def pre_window(ctx: Context, u: int, length: int = PRE_WINDOW_MIN) -> PreWindow:
  """Vectorised over all anchors. Ties go to the window's last minute when it is among the tied contexts, else
  to the lowest context index."""
  code = ctx.code
  n = len(code); k = len(CONTEXTS)
  onehot = np.zeros((n + 1, k), np.int64)
  onehot[np.arange(n) + 1, code] = 1
  csum = np.cumsum(onehot, axis=0)
  i = np.arange(n)
  hi = i - u; lo = hi - length
  ok = lo >= 0
  hi_c = np.clip(hi, 0, n); lo_c = np.clip(lo, 0, n)
  counts = csum[hi_c] - csum[lo_c]
  last = code[np.clip(hi - 1, 0, n - 1)]
  score = counts * 10
  score[i, last] += 1
  dom = np.argmax(score, axis=1).astype(np.int64)
  share = counts[i, dom] / float(length)
  return PreWindow(dominant=np.where(ok, dom, -1), share=np.where(ok, share, 0.0),
                   last_group=np.where(ok, GROUP_OF_CODE[last], -1))


def event_context(ctx: Context, i: int, u: int, length: int = PRE_WINDOW_MIN):
  """(dominant context, share, last-minute group) of [i - u - 15, i - u) for one anchor."""
  n = len(ctx.code)
  hi = i - u; lo = hi - length
  if lo < 0 or hi > n:
    return -1, 0.0, -1
  seg = ctx.code[lo:hi]
  score = np.bincount(seg, minlength=len(CONTEXTS)) * 10
  score[seg[-1]] += 1
  dom = int(np.argmax(score))
  return dom, float(np.mean(seg == dom)), int(GROUP_OF_CODE[seg[-1]])


def onset_group(ctx: Context, u: int) -> np.ndarray:
  """Dominant report group (asleep/still/walking/active/unknown) over [i - u, i] for every anchor i; ties go to the
  group at i. With u = 0 this is the group at the onset minute itself."""
  g = GROUP_OF_CODE[ctx.code]
  n = len(g); k = len(_GROUP_NAMES)
  onehot = np.zeros((n + 1, k), np.int64)
  onehot[np.arange(n) + 1, g] = 1
  csum = np.cumsum(onehot, axis=0)
  i = np.arange(n)
  counts = csum[i + 1] - csum[np.maximum(0, i - u)]
  score = counts * 10
  score[i, g] += 1
  return np.argmax(score, axis=1).astype(np.int64)
