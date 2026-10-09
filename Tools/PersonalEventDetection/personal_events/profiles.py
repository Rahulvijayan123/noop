"""Event-locked profiles, onset alignment, matched controls and paired differences
(docs/PHENOTYPE_SIGNATURES.md, section 4).

Two families of paired differences per event:
- level: window mean of the context-normalised z (and its residual in analysis units) minus the same over the
  event's matched controls ("vs what is usual for the activity and time of day");
- change: in physical units, (event window - event's own pre-onset window) minus the same over its controls
  ("change from before onset"). It is immune to night-to-night offsets and to movement being explained away by
  the activity-aware baseline.

Onset alignment (when >= 4 events) moves each logged onset within +/- its uncertainty to the leave-one-out mean
HR profile. Controls are re-aligned by the identical rule against the same template, which keeps the sign-flip
null valid; the cost is power: controls also gain the alignment's "best match to the template" bonus, so the
paired difference understates the event's alignment gain (largest for 15-60 min uncertainties).
"""
from __future__ import annotations

import dataclasses

import numpy as np

from .baseline import CHANNELS, Deviation, near_intervals
from .context import C, GROUP_OF_CODE, Context, event_context, onset_group, pre_window
from .timeline import Timeline

LAG = 30
LAGS = np.arange(-LAG, LAG + 1)
WINDOWS = ((-30, -15), (-15, -5), (-5, 0), (0, 5), (5, 15), (15, 30))
MAX_CONTROLS = 8
MIN_CONTROLS = 3
TOD_WINDOWS_MIN = (60, 120, 240)       # widened in turn while an event has fewer than MIN_CONTROLS controls
MIN_PRE_SHARE = 0.7
# Optional extra match on the activity group around the logged onset: None, "minute" (the onset minute) or
# "range" (dominant group over [onset - u, onset]). See ONSET_MATCH_NOTE.
ONSET_MATCH = None
SHARE_TOLERANCE = 0.1                  # control share >= max(0.7, event share - 0.1): composition, not just majority
MAX_UNCERTAINTY_MIN = 60
CHANGE_CHANNELS = ("hr", "hrv", "temp", "resp", "motion", "steps")
CHANGE_UNITS = {"hr": "bpm", "hrv": "ms", "temp": "°C", "resp": "breaths/min", "motion": "g", "steps": "steps/min"}
CHANGE_WINDOWS = ((0, 5), (5, 15), (15, 30))
CHANGE_PRE = (15, 5)                   # pre = [-(u + 15), -(u + 5)) relative to the logged onset
CHANGE_FLOORS = {"hr": 1.0, "hrv": 2.0, "temp": 0.05, "resp": 0.3, "motion": 0.005, "steps": 2.0}
CONTROL_MARGIN_S = 2 * 3600
MIN_HR_COVERAGE = 0.7
MIN_ALIGN_EVENTS = 4
MIN_ALIGN_OVERLAP = 40


def window_slices():
  """Profile index ranges per window; the last window [15, 30] includes lag 30."""
  out = []
  for a, b in WINDOWS:
    out.append((a + LAG, (b + LAG + 1) if b == LAG else (b + LAG)))
  return out


def profile(values: np.ndarray, idx: int) -> np.ndarray:
  n = len(values)
  out = np.full(len(LAGS), np.nan)
  lo, hi = idx - LAG, idx + LAG + 1
  a, b = max(lo, 0), min(hi, n)
  if b > a:
    out[a - lo:b - lo] = values[a:b]
  return out


def profiles(values: np.ndarray, idxs) -> np.ndarray:
  idxs = np.asarray(idxs, dtype=np.int64)
  if not len(idxs):
    return np.empty((0, len(LAGS)))
  pos = idxs[:, None] + LAGS[None, :]
  ok = (pos >= 0) & (pos < len(values))
  out = np.full(pos.shape, np.nan)
  out[ok] = values[pos[ok]]
  return out


def _corr(a, b):
  ok = np.isfinite(a) & np.isfinite(b)
  if ok.sum() < MIN_ALIGN_OVERLAP:
    return np.nan
  x = a[ok] - a[ok].mean(); y = b[ok] - b[ok].mean()
  d = np.sqrt((x * x).sum() * (y * y).sum())
  return float((x * y).sum() / d) if d > 0 else np.nan


def best_shift(values, idx, template, max_shift):
  """Shift within +/- max_shift minutes whose profile correlates best with the template; ties -> smallest |s|."""
  if template is None or max_shift <= 0:
    return 0
  best, best_r = 0, -np.inf
  for s in sorted(range(-max_shift, max_shift + 1), key=lambda s: (abs(s), s)):
    r = _corr(profile(values, idx + s), template)
    if np.isfinite(r) and r > best_r + 1e-12:
      best, best_r = s, r
  return best


def loo_templates(hr_z, idxs):
  """Leave-one-out mean HR z profile per event (None when fewer than MIN_ALIGN_EVENTS events)."""
  if len(idxs) < MIN_ALIGN_EVENTS:
    return [None] * len(idxs)
  P = profiles(hr_z, idxs)
  finite = np.isfinite(P)
  total = np.where(finite, P, 0).sum(axis=0); count = finite.sum(axis=0)
  out = []
  for k in range(len(idxs)):
    t = total - np.where(finite[k], P[k], 0); c = count - finite[k]
    with np.errstate(invalid="ignore", divide="ignore"):
      out.append(np.where(c > 0, t / np.maximum(c, 1), np.nan))
  return out


def control_base(tl: Timeline, ctx: Context, exclusions, preferred_spans, hi_index=None):
  """Context-free candidate mask shared by every event: whole +/- 30 min window inside the timeline (and before
  the cutoff), >= 2 h from every excluded span, worn, HR coverage >= 70 %, not off-wrist."""
  n = len(tl)
  hr_ok = np.isfinite(tl["hr"]).astype(np.int64)
  csum = np.r_[0, np.cumsum(hr_ok)]
  pos = np.arange(n)
  lo = pos - LAG; hi = pos + LAG + 1
  inside = (lo >= 0) & (hi <= (n if hi_index is None else min(n, hi_index)))
  cov = np.where(inside, (csum[np.clip(hi, 0, n)] - csum[np.clip(lo, 0, n)]) / len(LAGS), 0.0)
  far = ~near_intervals(tl, exclusions, CONTROL_MARGIN_S)
  base = inside & far & tl["wear"] & (cov >= MIN_HR_COVERAGE) & (ctx.code != C["off"])
  preferred = near_intervals(tl, preferred_spans, 0) if preferred_spans else np.zeros(n, bool)
  return base, preferred


def _pick(cand, preferred, day, rng, n_controls=MAX_CONTROLS):
  """Preferred (observation / reviewed negative) time first; otherwise a uniform random sample (without
  replacement) of candidate MINUTES. Any rule that caps controls per day or per walk (one per day, >= 61 min
  apart) weights days/bouts equally and over-samples short ones (e.g. walks about to end), which biased the
  walking null; a uniform sample does not. Controls may therefore overlap in time."""
  if not len(cand):
    return []
  order = cand[np.lexsort((rng.random(len(cand)), ~preferred[cand]))]
  return [int(j) for j in order[:n_controls]]


def matched_controls(tl: Timeline, ctx: Context, base, preferred, event_idxs, event_u, event_pre, rng,
                     n_controls=MAX_CONTROLS):
  """Per event up to 8 control anchors whose own pre-window [j - u - 15, j - u) has the event's dominant context
  with a share >= max(0.7, the event's share - 0.1) and the same context group in its last minute, at a local time of day within +/- 60 min
  (widened to 120 and 240 min while fewer than 3 are found), on another local day, >= 2 h from any logged event /
  positive review / unreviewed detection, worn, HR coverage >= 70 %.
  Returns (controls, preferred counts, time window used per event)."""
  tod = ((tl.minutes + tl.tz_offset_s) % 86400) // 60
  day = tl.local_day
  cache, gcache = {}, {}
  out, npref, widths = [], [], []
  for i, u, (dom, event_share, last_group) in zip(event_idxs, event_u, event_pre):
    if u not in cache:
      cache[u] = pre_window(ctx, u)
    pw = cache[u]
    share_needed = max(MIN_PRE_SHARE, event_share - SHARE_TOLERANCE)
    ok = base & (pw.dominant == dom) & (pw.share >= share_needed - 1e-9) & (pw.last_group == last_group) & (day != day[i])
    if ONSET_MATCH is not None:
      uu = u if ONSET_MATCH == "range" else 0
      if uu not in gcache:
        gcache[uu] = onset_group(ctx, uu)
      if ONSET_MATCH != "continuing" or gcache[uu][i] == GROUP_OF_CODE[dom]:
        ok &= gcache[uu] == gcache[uu][i]
    diff = np.abs(tod - tod[i]); diff = np.minimum(diff, 1440 - diff)
    chosen, width = [], TOD_WINDOWS_MIN[0]
    for width in TOD_WINDOWS_MIN:
      chosen = _pick(np.flatnonzero(ok & (diff <= width)), preferred, day, rng, n_controls)
      if len(chosen) >= MIN_CONTROLS:
        break
    out.append(chosen); npref.append(int(sum(preferred[j] for j in chosen))); widths.append(int(width))
  return out, npref, widths


@dataclasses.dataclass
class Paired:
  D_z: np.ndarray        # (E, C, W) level family: event window mean z - mean over controls
  D_res: np.ndarray      # (E, C, W) same in analysis units (bpm, ln ms, degC, /min, g)
  prof_res: np.ndarray   # (E, C, 61) per-lag paired difference in analysis units
  n_controls: np.ndarray # (E,)
  center: np.ndarray     # (E, C) expected value at onset (analysis units)
  win_z: list = None     # per event: (1 + controls, C, W) window-mean z; row 0 = the event (for label swaps)
  D_change: np.ndarray = None   # (E, 6, 3) change family in physical units (NaN when u > 15)
  change_scale: np.ndarray = None  # (6, 3) robust SD of control changes (physical units, floored)
  D_change_rank: np.ndarray = None  # (E, 6, 3) event's centred rank among its controls' changes, in [-1, 1]

  def subset(self, mask):
    idx = np.flatnonzero(mask)
    return Paired(D_z=self.D_z[mask], D_res=self.D_res[mask], prof_res=self.prof_res[mask],
                  n_controls=self.n_controls[mask], center=self.center[mask],
                  win_z=None if self.win_z is None else [self.win_z[k] for k in idx],
                  D_change=None if self.D_change is None else self.D_change[mask], change_scale=self.change_scale,
                  D_change_rank=None if self.D_change_rank is None else self.D_change_rank[mask])


def _window_means(P, slices):
  """P: (..., 61) -> (..., W) nan-mean per window, requiring at least half the minutes."""
  outs = []
  for a, b in slices:
    seg = P[..., a:b]
    cnt = np.isfinite(seg).sum(axis=-1)
    with np.errstate(invalid="ignore", divide="ignore"):
      m = np.where(cnt * 2 >= (b - a), np.nansum(seg, axis=-1) / np.maximum(cnt, 1), np.nan)
    outs.append(m)
  return np.stack(outs, axis=-1)


def raw_channel(tl: Timeline, ch: str) -> np.ndarray:
  """Physical units for the change family: bpm, RMSSD ms, degC, breaths/min, g, steps/min."""
  if ch == "hrv":
    return np.exp(tl["ln_rmssd"])
  return {"hr": tl["hr"], "temp": tl["temp"], "resp": tl["resp"], "motion": tl["motion"], "steps": tl["steps"]}[ch]


def _seg_mean(x, a, b):
  a, b = max(a, 0), min(b, len(x))
  if b <= a:
    return np.nan
  seg = x[a:b]
  f = np.isfinite(seg)
  return float(seg[f].mean()) if f.sum() * 2 >= (b - a) else np.nan


def change_vector(x, pre_anchor, post_anchor, u):
  """(post window - pre window) for the change windows; NaN when the pre window would start before -30."""
  out = np.full(len(CHANGE_WINDOWS), np.nan)
  if u + CHANGE_PRE[0] > LAG:
    return out
  pre = _seg_mean(x, pre_anchor - u - CHANGE_PRE[0], pre_anchor - u - CHANGE_PRE[1])
  if not np.isfinite(pre):
    return out
  for w, (a, b) in enumerate(CHANGE_WINDOWS):
    out[w] = _seg_mean(x, post_anchor + a, post_anchor + b + (1 if b == LAG else 0)) - pre
  return out


def paired_differences(dev: Deviation, event_idxs, control_idxs, *, tl=None, raw_event_idxs=None,
                       raw_control_idxs=None, event_u=None) -> Paired:
  E = len(event_idxs); nC = len(CHANNELS)
  slices = window_slices(); W = len(slices)
  D_z = np.full((E, nC, W), np.nan); D_res = np.full((E, nC, W), np.nan)
  prof = np.full((E, nC, len(LAGS)), np.nan); center = np.full((E, nC), np.nan)
  ncon = np.array([len(c) for c in control_idxs], dtype=np.int64)
  win_z = [np.full((1 + len(c), nC, W), np.nan) for c in control_idxs]
  for ci, ch in enumerate(CHANNELS):
    for kind, arr, target in (("z", dev.z[ch], D_z), ("res", dev.residual[ch], D_res)):
      ev = profiles(arr, event_idxs)
      evw = _window_means(ev, slices)
      for e in range(E):
        if not len(control_idxs[e]):
          continue
        cp = profiles(arr, control_idxs[e])
        cw = _window_means(cp, slices)
        cnt_w = np.isfinite(cw).sum(axis=0)
        with np.errstate(invalid="ignore", divide="ignore"):
          cmean = np.where(cnt_w > 0, np.nansum(cw, axis=0) / np.maximum(cnt_w, 1), np.nan)
        target[e, ci] = evw[e] - cmean
        if kind == "z":
          win_z[e][0, ci] = evw[e]; win_z[e][1:, ci] = cw
        if kind == "res":
          cnt = np.isfinite(cp).sum(axis=0)
          with np.errstate(invalid="ignore", divide="ignore"):
            cl = np.where(cnt > 0, np.nansum(cp, axis=0) / np.maximum(cnt, 1), np.nan)
          prof[e, ci] = ev[e] - cl
    for e, i in enumerate(event_idxs):
      seg = dev.expected[ch][max(0, i - 5):i + 1]
      seg = seg[np.isfinite(seg)]
      center[e, ci] = float(np.median(seg)) if len(seg) else np.nan
  D_change = np.full((E, len(CHANGE_CHANNELS), len(CHANGE_WINDOWS)), np.nan)
  D_rank = np.full_like(D_change, np.nan)
  scale = np.full((len(CHANGE_CHANNELS), len(CHANGE_WINDOWS)), np.nan)
  if tl is not None and E:
    raw_event_idxs = event_idxs if raw_event_idxs is None else raw_event_idxs
    raw_control_idxs = control_idxs if raw_control_idxs is None else raw_control_idxs
    event_u = [0] * E if event_u is None else event_u
    for ci, ch in enumerate(CHANGE_CHANNELS):
      x = raw_channel(tl, ch)
      pooled = []
      for e in range(E):
        u = int(event_u[e])
        ev = change_vector(x, raw_event_idxs[e], event_idxs[e], u)
        cs = np.array([change_vector(x, rj, j, u) for rj, j in zip(raw_control_idxs[e], control_idxs[e])])
        if not len(cs):
          continue
        pooled.append(cs)
        cnt = np.isfinite(cs).sum(axis=0)
        with np.errstate(invalid="ignore", divide="ignore"):
          cm = np.where(cnt > 0, np.nansum(cs, axis=0) / np.maximum(cnt, 1), np.nan)
        D_change[e, ci] = ev - cm
        # Centred rank of the event among its controls: exactly symmetric when the event window is exchangeable
        # with its control windows, which the sign-flip test needs. Raw changes are often bimodal (a walk goes on
        # or stops), so event - mean(controls) is skewed even under the null.
        fin = np.isfinite(cs)
        below = np.where(fin, cs < ev[None, :], False).sum(0) + 0.5 * np.where(fin, cs == ev[None, :], False).sum(0)
        half = cnt / 2.0
        with np.errstate(invalid="ignore", divide="ignore"):
          D_rank[e, ci] = np.where(np.isfinite(ev) & (cnt >= MIN_CONTROLS), (below - half) / half, np.nan)
      if pooled:
        P = np.concatenate(pooled)
        for w in range(len(CHANGE_WINDOWS)):
          v = P[:, w][np.isfinite(P[:, w])]
          sd = 1.4826 * float(np.median(np.abs(v - np.median(v)))) if len(v) >= 5 else np.nan
          scale[ci, w] = max(sd, CHANGE_FLOORS[ch]) if np.isfinite(sd) else CHANGE_FLOORS[ch]
  return Paired(D_z=D_z, D_res=D_res, prof_res=prof, n_controls=ncon, center=center, win_z=win_z,
                D_change=D_change, change_scale=scale, D_change_rank=D_rank)


def build(tl: Timeline, ctx: Context, dev: Deviation, events, *, exclusions, preferred_spans, rng,
          hi_index=None, align=True):
  """Locate, align and pair a list of events. Returns a dict with usable events and their paired differences.
  Dropped events are recorded with a reason: outside recorded time, strap not worn before onset, fewer than 3
  matched controls, no usable physiology around onset."""
  n = len(tl)
  limit = n if hi_index is None else min(n, hi_index)
  base, preferred = control_base(tl, ctx, exclusions, preferred_spans, hi_index)
  raw_idx, keep, dropped, us, pres = [], [], [], [], []
  for e in events:
    i = int(tl.index(e.start))
    u = int(round(min(max(e.uncertainty_min, 0), MAX_UNCERTAINTY_MIN)))
    if not (i - LAG >= 0 and i + LAG < limit):
      dropped.append((e.id, "outside recorded time")); continue
    pre = event_context(ctx, i, u)
    if pre[0] == -1:
      dropped.append((e.id, "outside recorded time")); continue
    if pre[0] == C["off"] or not np.isfinite(tl["hr"][max(0, i - LAG):i + LAG + 1]).any():
      dropped.append((e.id, "strap not worn before onset")); continue
    raw_idx.append(i); keep.append(e); us.append(u); pres.append(pre)
  hr_z = dev.z["hr"]
  templates = loo_templates(hr_z, raw_idx) if align else [None] * len(raw_idx)
  shifts = []
  for i, u, t in zip(raw_idx, us, templates):
    shifts.append(best_shift(hr_z, i, t, min(u, i - LAG, limit - 1 - LAG - i)))
  idx = [i + s for i, s in zip(raw_idx, shifts)]
  anchors, npref, widths = matched_controls(tl, ctx, base, preferred, raw_idx, us, pres, rng)
  # Controls are re-aligned exactly like their event (same template, same bound): alignment cannot create a
  # difference between events and controls under the null (see the module docstring for its power cost).
  controls = []
  for u, t, cs in zip(us, templates, anchors):
    controls.append([j + best_shift(hr_z, j, t, max(min(u, j - LAG, limit - 1 - LAG - j), 0)) for j in cs])
  usable = [k for k in range(len(keep)) if len(controls[k]) >= MIN_CONTROLS]
  for k in range(len(keep)):
    if len(controls[k]) < MIN_CONTROLS:
      dropped.append((keep[k].id, "fewer than 3 matched controls"))
  pick = lambda seq: [seq[k] for k in usable]
  paired = paired_differences(dev, pick(idx), pick(controls), tl=tl, raw_event_idxs=pick(raw_idx),
                              raw_control_idxs=pick(anchors), event_u=pick(us))
  E = len(usable)
  has_data = (np.isfinite(paired.D_z).reshape(E, -1).any(axis=1) |
              np.isfinite(paired.D_change).reshape(E, -1).any(axis=1)) if E else np.zeros(0, bool)
  for k in range(E):
    if not has_data[k]:
      dropped.append((keep[usable[k]].id, "no usable physiology around onset"))
  final = [usable[k] for k in range(E) if has_data[k]]
  paired = paired.subset(has_data) if E else paired
  at = lambda seq: [seq[k] for k in final]
  return dict(events=at(keep), idx=at(idx), raw_idx=at(raw_idx), shift=at(shifts), controls=at(controls),
              raw_controls=at(anchors), uncertainty=at(us), onset_context=[p[0] for p in at(pres)],
              pre_share=[p[1] for p in at(pres)], preferred=at(npref), control_window_min=at(widths),
              paired=paired, dropped=dropped, control_base=base)
