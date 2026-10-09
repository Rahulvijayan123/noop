"""Planted-event positive controls on real backgrounds.

A known effect is added to a real timeline at chosen onsets; the logged onset is jittered within the stated
onset uncertainty. Used to check that the engine recovers effects of known size, direction and timing, and to
calibrate detectability. Planted data never leaves memory and is never written back to any store.
"""
from __future__ import annotations

import dataclasses

import numpy as np

from .context import GROUPS, CONTEXTS, classify
from .evidence import Event
from .timeline import Timeline

# Channel -> timeline columns the effect is added to (hrv amplitude is in ln(RMSSD) units, e.g. -0.3 = -26 %).
TARGETS = {"hr": ("hr", "hr_max", "hr_min"), "hrv": ("ln_rmssd",), "temp": ("temp", "temp_detr"),
           "resp": ("resp",), "motion": ("motion", "motion_p90")}


@dataclasses.dataclass
class PlantSpec:
  n: int = 8
  effects: dict = dataclasses.field(default_factory=lambda: {"hr": 12.0})
  lag_min: float = 0.0
  duration_min: float = 10.0
  ramp_min: float = 2.0
  decay_min: float = 5.0
  uncertainty_min: float = 5.0
  context: str | None = "awake"      # awake | asleep | still | walking | active | None (any)
  spacing_h: float = 6.0
  per_day: int = 1
  jitter: bool = True
  type_id: str = "planted"
  seed: int = 0


def parse_spec(text: str) -> PlantSpec:
  """'n=8,hr=12,hrv=-0.3,lag=0,dur=10,unc=5,context=awake,per_day=1,seed=1'."""
  spec = PlantSpec(effects={})
  for part in filter(None, (p.strip() for p in (text or "").split(","))):
    key, _, value = part.partition("=")
    key = key.strip(); value = value.strip()
    if key in TARGETS:
      spec.effects[key] = float(value)
    elif key == "n":
      spec.n = int(value)
    elif key == "lag":
      spec.lag_min = float(value)
    elif key in ("dur", "duration"):
      spec.duration_min = float(value)
    elif key in ("unc", "uncertainty"):
      spec.uncertainty_min = float(value)
    elif key == "context":
      spec.context = None if value in ("any", "") else value
    elif key == "spacing":
      spec.spacing_h = float(value)
    elif key == "per_day":
      spec.per_day = int(value)
    elif key == "jitter":
      spec.jitter = value not in ("0", "false", "no")
    elif key == "seed":
      spec.seed = int(value)
    elif key == "type":
      spec.type_id = value
    else:
      raise ValueError(f"unknown inject key {key!r}")
  if not spec.effects:
    spec.effects = {"hr": 12.0}
  return spec


def shape(spec: PlantSpec, lags_min: np.ndarray) -> np.ndarray:
  """0 before onset + lag, linear ramp, plateau for the duration, exponential decay after."""
  t = lags_min - spec.lag_min
  out = np.zeros_like(t, dtype=np.float64)
  ramp = max(spec.ramp_min, 1e-9)
  on = (t >= 0) & (t < spec.duration_min)
  out[on] = np.minimum(1.0, (t[on] + 1) / ramp)
  after = t >= spec.duration_min
  out[after] = np.exp(-(t[after] - spec.duration_min) / max(spec.decay_min, 1e-9))
  return out


def _context_ok(code, wanted):
  if wanted is None:
    return np.ones(len(code), bool)
  if wanted == "awake":
    return (code != CONTEXTS.index("asleep")) & (code != CONTEXTS.index("off")) & (code != CONTEXTS.index("unknown"))
  members = GROUPS.get(wanted, (wanted,))
  return np.isin(code, [CONTEXTS.index(m) for m in members])


def choose_onsets(tl: Timeline, spec: PlantSpec, rng, avoid=()):
  n = len(tl)
  ctx = classify(tl)
  hr_ok = np.isfinite(tl["hr"]).astype(np.int64)
  cs = np.r_[0, np.cumsum(hr_ok)]
  pre, post = 30, int(30 + spec.lag_min + spec.duration_min + 3 * spec.decay_min)
  pos = np.arange(n)
  lo = pos - pre - 60; hi = pos + post + 60
  inside = (lo >= 0) & (hi < n)
  cov = np.where(inside, (cs[np.clip(pos + post, 0, n)] - cs[np.clip(pos - pre, 0, n)]) / (pre + post), 0)
  ok = inside & (cov >= 0.8) & tl["wear"] & _context_ok(ctx.code, spec.context)
  for a, b in avoid:
    i0 = int(np.clip((a - 3 * 3600 - tl.minutes[0]) // 60, 0, n)); i1 = int(np.clip((b + 3 * 3600 - tl.minutes[0]) // 60, 0, n))
    ok[i0:i1] = False
  cand = np.flatnonzero(ok)
  if not len(cand):
    return []
  day = tl.local_day
  days = np.unique(day[cand])
  rng.shuffle(days)
  chosen = []
  spacing = int(spec.spacing_h * 60)
  for rnd in range(spec.per_day):
    for d in days:
      if len(chosen) >= spec.n:
        break
      pool = cand[day[cand] == d]
      pool = pool[[all(abs(int(j) - k) >= spacing for k in chosen) for j in pool]] if chosen else pool
      if len(pool):
        chosen.append(int(rng.choice(pool)))
  return sorted(chosen)


def plant(tl: Timeline, spec: PlantSpec, avoid=()):
  """Returns (planted timeline copy, logged events, truth)."""
  rng = np.random.default_rng(spec.seed)
  out = tl.copy()
  onsets = choose_onsets(tl, spec, rng, avoid)
  span = int(30 + spec.lag_min + spec.duration_min + 6 * spec.decay_min)
  lags = np.arange(0, span)
  w = shape(spec, lags.astype(np.float64))
  events, truth = [], []
  for k, i in enumerate(onsets):
    sl = slice(i, min(len(tl), i + span))
    for ch, amp in spec.effects.items():
      for col in TARGETS[ch]:
        out.cols[col][sl] = out.cols[col][sl] + amp * w[: sl.stop - sl.start]   # NaN stays NaN
    true_onset = float(tl.minutes[i])
    offset = rng.uniform(-spec.uncertainty_min, spec.uncertainty_min) * 60 if spec.jitter else 0.0
    start = round(true_onset + offset)
    events.append(Event(id=f"planted-{spec.seed}-{k}", start=float(start),
                        end=float(start + max(spec.duration_min, 1) * 60), uncertainty_min=spec.uncertainty_min,
                        type_id=spec.type_id))
    truth.append({"id": events[-1].id, "true_onset": int(true_onset), "logged_onset": int(start)})
  return out, events, truth
