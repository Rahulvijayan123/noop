"""Synthetic minute timelines for tests. No personal data: every value is generated from a seed."""
import numpy as np

from personal_events.evidence import Event
from personal_events.timeline import assemble

T0 = 1_790_000_000 - 1_790_000_000 % 86400   # a UTC midnight


def make_timeline(days=20, seed=0, tz=0, motion=True, day_sd=2.0, noise_sd=3.0, resp=False):
  rng = np.random.default_rng(seed)
  n = days * 1440
  minutes = T0 + 60 * np.arange(n, dtype=np.int64)
  hour = ((minutes + tz) % 86400) / 3600
  day = (minutes + tz) // 86400
  asleep = (hour < 6) | (hour >= 23)
  # AR(1) minute noise + a per-day offset shared by every minute of the day (same-day state).
  e = rng.normal(0, noise_sd * np.sqrt(1 - 0.9 ** 2), n)
  ar = np.empty(n); ar[0] = e[0]
  for i in range(1, n):
    ar[i] = 0.9 * ar[i - 1] + e[i]
  uniq, inv = np.unique(day, return_inverse=True)
  day_eff = rng.normal(0, day_sd, len(uniq))[inv]
  walking = ~asleep & (rng.random(n) < 0.03)
  walking = walking | np.r_[False, walking[:-1]] | np.r_[False, False, walking[:-2]]
  hr = 58 + 12 * (~asleep) + 25 * walking + day_eff + ar
  hr_n = np.full(n, 60.0)
  mot = np.where(walking, 0.25, np.where(asleep, 0.01, 0.03)) * np.exp(rng.normal(0, 0.3, n))
  steps = np.where(walking, 100.0, 0.0)
  temp_raw = 3400 + 30 * np.sin(2 * np.pi * hour / 24) + rng.normal(0, 5, n)
  rmssd = np.exp(np.log(45) - 0.02 * (hr - 65) + rng.normal(0, 0.15, n))
  pairs = np.full(n, 55.0)
  sumsq = pairs * rmssd ** 2
  tl = assemble(minutes, tz, device="synthetic", hr=(hr, hr + 5, hr - 5, hr_n), rr=(sumsq, pairs),
                motion=(mot, mot * 1.5) if motion else None, steps=steps, temp_raw=temp_raw,
                sleep_frac=asleep.astype(float), resp=(14 + rng.normal(0, 1, n)) if resp else None)
  return tl


def event_onsets(tl, n_events, rng, per_day=1, hours=(9, 20), skip_days=3):
  """Awake onsets on distinct local days (or `per_day` per day), >= 3 h apart."""
  days = np.unique(tl.local_day)[skip_days:-1]
  out = []
  for d in days:
    for k in range(per_day):
      if len(out) >= n_events:
        break
      h = hours[0] + (hours[1] - hours[0]) * (k + rng.random()) / per_day
      out.append(int(d * 86400 - tl.tz_offset_s + int(h * 3600) // 60 * 60))
    if len(out) >= n_events:
      break
  return out


def plant_hr(tl, onsets, amp=15.0, duration=10, lag=0):
  t2 = tl.copy()
  for s in onsets:
    i = int(tl.index(s)) + lag
    for col in ("hr", "hr_max", "hr_min"):
      t2.cols[col][i:i + duration] += amp
  return t2


def events_at(onsets, unc=0.0, dur=10, type_id="T", prefix="e"):
  return [Event(id=f"{prefix}{k}", start=float(s), end=float(s + dur * 60), uncertainty_min=unc, type_id=type_id)
          for k, s in enumerate(onsets)]


def make_walking_timeline(days=16, seed=0, start_p=1 / 45, stay_p=0.96, tz=0):
  """Awake time with frequent walking bouts of geometric length (memoryless, mean 1 / (1 - stay_p) minutes).
  HR follows the walking load with a 2-minute time constant; steps and motion mark the walk."""
  rng = np.random.default_rng(seed)
  n = days * 1440
  minutes = T0 + 60 * np.arange(n, dtype=np.int64)
  hour = ((minutes + tz) % 86400) / 3600
  day = (minutes + tz) // 86400
  asleep = (hour < 6) | (hour >= 23)
  walking = np.zeros(n, bool)
  state = False
  u = rng.random(n)
  for i in range(n):
    state = (not asleep[i]) and ((u[i] < stay_p) if state else (u[i] < start_p))
    walking[i] = state
  load = np.zeros(n); a = np.exp(-1 / 2.0)
  for i in range(1, n):
    load[i] = a * load[i - 1] + (1 - a) * (25.0 if walking[i] else 0.0)
  uniq, inv = np.unique(day, return_inverse=True)
  e = rng.normal(0, 3 * np.sqrt(1 - 0.8 ** 2), n)
  ar = np.empty(n); ar[0] = e[0]
  for i in range(1, n):
    ar[i] = 0.8 * ar[i - 1] + e[i]
  hr = 58 + 12 * (~asleep) + load + rng.normal(0, 2.0, len(uniq))[inv] + ar
  mot = np.where(walking, 0.25, np.where(asleep, 0.01, 0.03)) * np.exp(rng.normal(0, 0.3, n))
  steps = np.where(walking, np.round(rng.normal(105, 8, n)), 0.0)
  temp_raw = 3400 + 30 * np.sin(2 * np.pi * hour / 24) + rng.normal(0, 5, n)
  pairs = np.full(n, 55.0)
  sumsq = pairs * np.exp(np.log(45) - 0.02 * (hr - 65) + rng.normal(0, 0.15, n)) ** 2
  return assemble(minutes, tz, device="synthetic-walk", hr=(hr, hr + 5, hr - 5, np.full(n, 60.0)),
                  rr=(sumsq, pairs), motion=(mot, mot * 1.5), steps=steps, temp_raw=temp_raw,
                  sleep_frac=asleep.astype(float)), walking


def mid_walk_onsets(tl, walking, n_events, rng, u=0, pre=15):
  """One onset per local day at a random minute whose whole pre-window [i - u - pre, i - u) is walking."""
  n = len(tl)
  cs = np.r_[0, np.cumsum(walking.astype(np.int64))]
  i = np.arange(n)
  ok = (i - u - pre >= 60) & (i + 90 < n)
  good = np.zeros(n, bool)
  good[ok] = (cs[i[ok] - u] - cs[i[ok] - u - pre]) == pre
  days = np.unique(tl.local_day)
  rng.shuffle(days)
  out = []
  for d in days:
    cand = np.flatnonzero(good & (tl.local_day == d))
    if len(cand):
      out.append(int(tl.minutes[rng.choice(cand)]))
    if len(out) >= n_events:
      break
  return sorted(out)
