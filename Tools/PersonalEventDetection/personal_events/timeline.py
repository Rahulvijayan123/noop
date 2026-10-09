"""One row per wall-clock minute of one device (docs/PHENOTYPE_SIGNATURES.md, section 1).

Both loaders return the same `Timeline`: numpy arrays, NaN = missing, never 0. Per-minute aggregation is shared
(`assemble`), so the server (Postgres) and phone (WhoopStore SQLite) paths cannot drift. R-R cleaning follows the
anomaly service's `rr.clean_beats` rules (transport pinning, suspect/duplicate/range/fill-value drops, Malik 20 %).
"""
from __future__ import annotations

import dataclasses
import json
import sqlite3

import numpy as np

ACTIVITY_CLASSES = ("sleeping", "lying_down", "sitting", "sitting_desk", "standing", "stationary", "fidgeting",
                    "light_activity", "walking", "brisk_walking", "running", "cycling", "vigorous_activity",
                    "off_wrist", "unknown")
POSTURES = ("recumbent", "seated_likely", "upright_stationary", "postural_transition")
_CLASS_CODE = {c: i for i, c in enumerate(ACTIVITY_CLASSES)}
_POSTURE_CODE = {p: i for i, p in enumerate(POSTURES)}

MIN_HR_SECONDS = 30
HR_RANGE = (25, 250)
RR_RANGE = (300, 2000)
RR_FILL_VALUES = (500, 333)
RMSSD_WINDOW_MIN = 2
RMSSD_MIN_PAIRS = 30
STILL_MOTION_G = 0.05
STILL_MOTION_P90_G = 0.15
TEMP_DETREND_MIN = 360
TEMP_DETREND_MIN_PRESENT = 30
WRIST_OFF_EXPIRY_S = 6 * 3600
STEP_COUNTER_MOD = 65536
RESP_RANGE = (4, 40)


@dataclasses.dataclass
class Timeline:
  minutes: np.ndarray                       # (N,) int64 minute starts, unix seconds
  cols: dict                                # name -> (N,) array
  tz_offset_s: int = 0
  device: str = ""
  meta: dict = dataclasses.field(default_factory=dict)

  def __getitem__(self, key):
    return self.cols[key]

  def __len__(self):
    return len(self.minutes)

  @property
  def local_day(self) -> np.ndarray:
    return (self.minutes + self.tz_offset_s) // 86400

  def index(self, ts) -> np.ndarray:
    """Minute index of unix time(s); may fall outside [0, N)."""
    return ((np.asarray(ts, dtype=np.float64) - float(self.minutes[0])) // 60).astype(np.int64)

  def copy(self) -> "Timeline":
    return Timeline(self.minutes.copy(), {k: v.copy() for k, v in self.cols.items()}, self.tz_offset_s,
                    self.device, dict(self.meta))

  def digest(self) -> str:
    import hashlib
    h = hashlib.sha256(self.minutes.tobytes())
    for k in sorted(self.cols):
      h.update(k.encode()); h.update(np.ascontiguousarray(self.cols[k]).tobytes())
    return h.hexdigest()


# --------------------------------------------------------------------------------------------- per-minute helpers

def minute_grid(lo: float, hi: float) -> np.ndarray:
  lo = int(lo) - int(lo) % 60
  hi = int(hi)
  return np.arange(lo, max(lo, hi - hi % 60 + (60 if hi % 60 else 0)), 60, dtype=np.int64)


def _bins(minutes, ts):
  i = (np.asarray(ts, dtype=np.int64) - int(minutes[0])) // 60
  return i, (i >= 0) & (i < len(minutes))


def hr_per_minute(minutes, ts, bpm):
  """mean / max / min / count of 25-250 bpm samples; NaN where fewer than 30 seconds are present."""
  n = len(minutes)
  ts = np.asarray(ts); bpm = np.asarray(bpm, dtype=np.float64)
  i, ok = _bins(minutes, ts)
  ok &= (bpm >= HR_RANGE[0]) & (bpm <= HR_RANGE[1])
  i = i[ok]; v = bpm[ok]
  count = np.bincount(i, minlength=n).astype(np.float64)
  total = np.bincount(i, weights=v, minlength=n)
  hi = np.full(n, -np.inf); lo = np.full(n, np.inf)
  np.maximum.at(hi, i, v); np.minimum.at(lo, i, v)
  enough = count >= MIN_HR_SECONDS
  with np.errstate(invalid="ignore", divide="ignore"):
    mean = np.where(enough, total / np.maximum(count, 1), np.nan)
  return mean, np.where(enough, hi, np.nan), np.where(enough, lo, np.nan), count


def grouped_mean_p90(minutes, ts, values):
  """Per-minute mean and linear-interpolated 90th percentile (numpy / percentile_cont semantics)."""
  n = len(minutes)
  v = np.asarray(values, dtype=np.float64)
  i, ok = _bins(minutes, ts)
  ok &= np.isfinite(v)
  i = i[ok]; v = v[ok]
  mean = np.full(n, np.nan); p90 = np.full(n, np.nan)
  if not len(i):
    return mean, p90
  order = np.lexsort((v, i))
  i = i[order]; v = v[order]
  uniq, start, count = np.unique(i, return_index=True, return_counts=True)
  sums = np.add.reduceat(v, start)
  mean[uniq] = sums / count
  pos = 0.9 * (count - 1)
  a = np.floor(pos).astype(np.int64); b = np.ceil(pos).astype(np.int64)
  va = v[start + a]; vb = v[start + b]
  p90[uniq] = va + (vb - va) * (pos - a)
  return mean, p90


def mean_per_minute(minutes, ts, values):
  n = len(minutes)
  v = np.asarray(values, dtype=np.float64)
  i, ok = _bins(minutes, ts)
  ok &= np.isfinite(v)
  count = np.bincount(i[ok], minlength=n)
  total = np.bincount(i[ok], weights=v[ok], minlength=n)
  with np.errstate(invalid="ignore", divide="ignore"):
    return np.where(count > 0, total / np.maximum(count, 1), np.nan)


def steps_per_minute(minutes, ts, counter):
  """Per-minute delta of the strap step counter. Wraps are handled modulo 2^16; a reset or implausible jump
  makes that minute NaN; a minute with no consecutive pair of samples <= 90 s apart is NaN (unknown, not 0)."""
  n = len(minutes)
  out = np.full(n, np.nan)
  ts = np.asarray(ts, dtype=np.int64); c = np.asarray(counter, dtype=np.int64)
  if len(ts) < 2:
    return out
  order = np.argsort(ts, kind="stable"); ts = ts[order]; c = c[order]
  dt = np.diff(ts)
  d = (c[1:] - c[:-1]) % STEP_COUNTER_MOD
  valid = (dt > 0) & (dt <= 90)
  bad = valid & (d > 5 * dt + 5)
  i, ok = _bins(minutes, ts[1:])
  use = ok & valid
  count = np.bincount(i[use], minlength=n)
  total = np.bincount(i[use & ~bad], weights=d[use & ~bad].astype(np.float64), minlength=n)
  nbad = np.bincount(i[use & bad], minlength=n)
  good = (count > 0) & (nbad == 0)
  out[good] = total[good]
  return out


def rr_pairs_per_minute(minutes, ts, rr, seq=None, channel=None, suspect=None, hr_mean=None, ord_=None):
  """Clean R-R beats and return, per minute of the later beat, the sum of squared successive differences and
  the number of accepted pairs. Rules mirror Tools/AnomalyService rr.clean_beats + rmssd_per_minute: one
  transport per minute (channel 5 wins over 7 where both are present), tsSuspect dropped, exact duplicates
  (ts, rrMs, seq) dropped, 300-2000 ms, transport fill values 500/333 ms dropped unless concurrent HR >= 100,
  pairs only between beats <= 3 s apart and |delta| <= 20 % of the previous interval (Malik).
  Beat order: stable by (ts, ord, seq, input order) - several beats share one second, and their order within
  the second is the transport's `ord` (missing ord sorts last), never the interval value. Input order must be
  insertion order (the loaders read rowid / ctid order)."""
  n = len(minutes)
  ts = np.asarray(ts, dtype=np.int64); rr = np.asarray(rr, dtype=np.int64)
  m = len(ts)
  seq = np.zeros(m, np.int64) if seq is None else np.nan_to_num(np.asarray(seq, dtype=np.float64)).astype(np.int64)
  ch = np.full(m, -1, np.int64) if channel is None else np.nan_to_num(np.asarray(channel, dtype=np.float64), nan=-1).astype(np.int64)
  sus = np.zeros(m, bool) if suspect is None else np.nan_to_num(np.asarray(suspect, dtype=np.float64)).astype(bool)
  od = np.full(m, np.inf) if ord_ is None else np.asarray(ord_, dtype=np.float64)
  od = np.where(np.isfinite(od), od, np.inf)
  ins = np.arange(m)
  sumsq = np.zeros(n); pairs = np.zeros(n)
  counters = {"input": int(m)}
  if m < 2:
    return sumsq, pairs, counters
  i, ok = _bins(minutes, ts)
  has5 = np.zeros(n, bool)
  has5[i[ok & (ch == 5)]] = True
  keep = ok & ~sus & ~((ch == 7) & np.where(ok, has5[np.clip(i, 0, n - 1)], False))
  keep &= (rr >= RR_RANGE[0]) & (rr <= RR_RANGE[1])
  if hr_mean is not None:
    hr_at = np.where(ok, hr_mean[np.clip(i, 0, n - 1)], np.nan)
    fill = np.isin(rr, RR_FILL_VALUES) & ~(hr_at >= 100)
    keep &= ~fill
  else:
    keep &= ~np.isin(rr, RR_FILL_VALUES)
  ts, rr, seq, i, od, ins = ts[keep], rr[keep], seq[keep], i[keep], od[keep], ins[keep]
  order = np.lexsort((ins, seq, od, ts))
  ts, rr, seq, i = ts[order], rr[order], seq[order], i[order]
  if len(ts) > 1:
    # Exact duplicates (ts, rrMs, seq) anywhere within the second: keep the first in beat order.
    pos = np.arange(len(ts))
    o2 = np.lexsort((pos, seq, rr, ts))
    same = np.r_[False, (ts[o2][1:] == ts[o2][:-1]) & (rr[o2][1:] == rr[o2][:-1]) & (seq[o2][1:] == seq[o2][:-1])]
    dup = np.zeros(len(ts), bool); dup[o2[same]] = True
    ts, rr, i = ts[~dup], rr[~dup], i[~dup]
  rr = rr.astype(np.float64)
  counters["clean"] = int(len(ts))
  if len(ts) < 2:
    return sumsq, pairs, counters
  d = np.diff(rr)
  good = (np.diff(ts) <= 3) & (np.abs(d) <= 0.2 * rr[:-1])
  j = i[1:][good]
  sumsq = np.bincount(j, weights=d[good] ** 2, minlength=n)
  pairs = np.bincount(j, minlength=n).astype(np.float64)
  return sumsq, pairs, counters


def interval_lookup(minutes, starts, ends):
  """Index of the interval covering each minute's midpoint (latest start wins), -1 where none."""
  starts = np.asarray(starts, dtype=np.float64); ends = np.asarray(ends, dtype=np.float64)
  if not len(starts):
    return np.full(len(minutes), -1, np.int64)
  order = np.argsort(starts, kind="stable")
  s = starts[order]; e = ends[order]
  mid = minutes.astype(np.float64) + 30
  k = np.searchsorted(s, mid, side="right") - 1
  hit = (k >= 0) & (e[np.clip(k, 0, None)] > mid)
  return np.where(hit, order[np.clip(k, 0, None)], -1)


def _trailing_median(values, window, min_present):
  n = len(values)
  out = np.full(n, np.nan)
  finite = np.isfinite(values)
  if finite.sum() < min_present:
    return out
  padded = np.r_[np.full(window - 1, np.nan), values]
  view = np.lib.stride_tricks.sliding_window_view(padded, window)
  counts = np.convolve(finite.astype(np.int64), np.ones(window, np.int64))[:n]
  rows = np.flatnonzero(finite & (counts >= min_present))
  for a in range(0, len(rows), 4096):
    r = rows[a:a + 4096]
    with np.errstate(all="ignore"):
      out[r] = np.nanmedian(view[r], axis=1)
  return out


def skin_temp_celsius(raw, family=None):
  """WHOOP 5/MG report centidegrees; WHOOP 4.0 raw ADC -> 33 + 0.05 (raw - device anchor) (same rule as the
  anomaly service). Values outside 25-42 degC are NaN."""
  raw = np.asarray(raw, dtype=np.float64)
  finite = raw[np.isfinite(raw)]
  fam = (family or "").lower()
  if "4" in fam or (not fam and len(finite) and np.nanmedian(finite) < 2500):
    band = finite[(finite >= 550) & (finite <= 2040)]
    anchor = float(np.median(band)) if len(band) >= 100 else 826.0
    temp, mapping = 33.0 + 0.05 * (raw - anchor), "whoop4-anchor"
  else:
    temp, mapping = raw / 100.0, "centidegree"
  return np.where((temp >= 25) & (temp <= 42), temp, np.nan), mapping


# --------------------------------------------------------------------------------------------- assembly

def assemble(minutes, tz_offset_s=0, *, device="", hr=None, rr=None, motion=None, steps=None, temp_raw=None,
             sleep_frac=None, wrist=(), activity=None, resp=None, sleep_sessions=(), family=None) -> Timeline:
  """hr: (mean, max, min, n); rr: (sumsq, pairs); motion: (mean, p90); steps, temp_raw, sleep_frac, resp:
  per-minute arrays (NaN = missing); wrist: [(ts, on: bool)]; activity: dict of arrays per interval with keys
  start, end, cls, conf, posture, sleep, wear, resp and optional rank (1 preferred); sleep_sessions: [(s, e)]."""
  n = len(minutes)
  nan = lambda: np.full(n, np.nan)
  hr_mean, hr_max, hr_min, hr_n = hr if hr is not None else (nan(), nan(), nan(), np.zeros(n))
  motion_mean, motion_p90 = motion if motion is not None else (nan(), nan())
  steps = nan() if steps is None else np.asarray(steps, dtype=np.float64)
  sleep_frac = nan() if sleep_frac is None else np.asarray(sleep_frac, dtype=np.float64)
  resp_min = nan() if resp is None else np.asarray(resp, dtype=np.float64)

  # Activity classifier output at the minute midpoint; rank 1 (raw-IMU) where it exists, else rank 2.
  act = np.full(n, -1, np.int64); act_conf = nan(); posture = np.full(n, -1, np.int64)
  act_sleep = np.zeros(n, bool); act_off = np.zeros(n, bool); act_resp = nan()
  if activity is not None and len(activity.get("start", ())):
    a = {k: np.asarray(v, dtype=object if k in ("cls", "posture", "sleep", "wear") else np.float64)
         for k, v in activity.items()}
    ranks = a.get("rank")
    ranks = np.ones(len(a["start"])) if ranks is None else np.asarray(ranks, dtype=np.float64)
    filled = np.zeros(n, bool)
    for rank in sorted(set(ranks.tolist())):
      sel = np.flatnonzero(ranks == rank)
      k = interval_lookup(minutes, a["start"][sel], a["end"][sel])
      hit = (k >= 0) & ~filled
      idx = sel[k[hit]]
      act[hit] = [_CLASS_CODE.get(str(c) if c is not None else "unknown", _CLASS_CODE["unknown"]) for c in a["cls"][idx]]
      act_conf[hit] = a["conf"][idx]
      posture[hit] = [_posture_code(p) for p in a["posture"][idx]]
      act_sleep[hit] = [str(s) == "asleep" for s in a["sleep"][idx]]
      act_off[hit] = [str(w) == "off_wrist" for w in a["wear"][idx]]
      if "resp" in a:
        act_resp[hit] = a["resp"][idx]
      filled |= hit
    act_off |= act == _CLASS_CODE["off_wrist"]

  resp_all = np.where(np.isfinite(resp_min), resp_min, act_resp)
  resp_all = np.where((resp_all >= RESP_RANGE[0]) & (resp_all <= RESP_RANGE[1]), resp_all, np.nan)

  # Wrist-off from strap events: the last WRIST_ON/OFF at or before the minute's end; an OFF expires after 6 h
  # (a lost ON event must not blank weeks; HR presence still gates wear).
  wrist_off = np.zeros(n, bool)
  if len(wrist):
    w = sorted(wrist)
    wts = np.array([t for t, _ in w], dtype=np.float64); won = np.array([o for _, o in w], bool)
    k = np.searchsorted(wts, minutes + 60.0, side="right") - 1
    valid = k >= 0
    kk = np.clip(k, 0, None)
    wrist_off = valid & ~won[kk] & (minutes + 60.0 - wts[kk] <= WRIST_OFF_EXPIRY_S)
  wear = (hr_n >= MIN_HR_SECONDS) & ~wrist_off & ~act_off

  # Asleep: strap sleep state where present (state 2 = asleep, majority of the minute), else inside a sleep
  # session/night = 1, else unknown.
  asleep = np.where(np.isfinite(sleep_frac), (sleep_frac >= 0.5).astype(np.float64), np.nan)
  if len(sleep_sessions):
    ss = np.asarray(sleep_sessions, dtype=np.float64)
    k = interval_lookup(minutes, ss[:, 0], ss[:, 1])
    asleep = np.where(np.isnan(asleep) & (k >= 0), 1.0, asleep)

  # RMSSD: trailing 2-minute window ending at the minute; only where motion is OK in every window minute.
  sumsq, pairs = rr if rr is not None else (np.zeros(n), np.zeros(n))
  ws = np.convolve(sumsq, np.ones(RMSSD_WINDOW_MIN))[:n]
  wp = np.convolve(pairs, np.ones(RMSSD_WINDOW_MIN))[:n]
  still_known = np.isfinite(motion_mean)
  still_min = still_known & (motion_mean < STILL_MOTION_G) & ~(motion_p90 >= STILL_MOTION_P90_G)
  # Without accelerometer data a minute counts as still only with zero steps and a still/sleep activity class.
  still_classes = np.isin(act, [_CLASS_CODE[c] for c in ("sleeping", "lying_down", "sitting", "sitting_desk",
                                                          "standing", "stationary")])
  still_min |= ~still_known & (steps == 0) & (still_classes | (asleep == 1))
  motion_ok = np.convolve(still_min.astype(np.int64), np.ones(RMSSD_WINDOW_MIN, np.int64))[:n] == RMSSD_WINDOW_MIN
  enough = wp >= RMSSD_MIN_PAIRS
  with np.errstate(invalid="ignore", divide="ignore"):
    rmssd = np.sqrt(ws / np.maximum(wp, 1))
  ln_rmssd = np.where(enough & motion_ok & (rmssd > 0), np.log(np.where(rmssd > 0, rmssd, 1.0)), np.nan)
  motion_artifact = enough & ~motion_ok

  temp_raw = nan() if temp_raw is None else np.asarray(temp_raw, dtype=np.float64)
  temp, mapping = skin_temp_celsius(temp_raw, family)
  temp_detr = temp - _trailing_median(temp, TEMP_DETREND_MIN, TEMP_DETREND_MIN_PRESENT)

  local_hour = ((minutes + tz_offset_s) % 86400) / 3600.0
  cols = dict(hr=hr_mean, hr_max=hr_max, hr_min=hr_min, hr_n=np.asarray(hr_n, dtype=np.float64),
              ln_rmssd=ln_rmssd, rr_pairs=wp, motion_artifact=motion_artifact,
              motion=motion_mean, motion_p90=motion_p90, steps=steps, temp=temp, temp_detr=temp_detr,
              resp=resp_all, asleep=asleep, activity=act, activity_conf=act_conf, posture=posture,
              activity_asleep=act_sleep, wrist_off=wrist_off, wear=wear, local_hour=local_hour)
  return Timeline(minutes=minutes, cols=cols, tz_offset_s=int(tz_offset_s), device=str(device),
                  meta={"temp_mapping": mapping})


def _posture_code(p):
  if p is None:
    return -1
  if isinstance(p, str):
    s = p.strip()
    if s.startswith("{"):
      try:
        p = json.loads(s)
      except json.JSONDecodeError:
        return -1
    else:
      return _POSTURE_CODE.get(s, -1)
  if isinstance(p, dict):
    probs = {k: v for k, v in p.items() if k in _POSTURE_CODE and isinstance(v, (int, float))}
    if not probs:
      return -1
    best = max(sorted(probs), key=lambda k: probs[k])
    return _POSTURE_CODE[best] if probs[best] >= 0.5 else -1
  return -1


def _wrist_events(rows):
  out = []
  for ts, kind in rows:
    k = str(kind)
    if k.startswith("WRIST_ON"):
      out.append((float(ts), True))
    elif k.startswith("WRIST_OFF"):
      out.append((float(ts), False))
  return out


# --------------------------------------------------------------------------------------------- loaders

def load_whoop_sqlite(path, device, lo, hi, tz_offset_s=0) -> Timeline:
  """Read a WhoopStore database strictly read-only (`mode=ro`). Nothing is written."""
  uri = "file:" + str(path) + "?mode=ro"
  conn = sqlite3.connect(uri, uri=True)
  try:
    def cols_of(table):
      return {r[1] for r in conn.execute(f'pragma table_info("{table}")')}

    def fetch(table, columns, ts_col="ts", pad=0):
      present = cols_of(table)
      if not present:
        return np.empty((0, len(columns)))
      where = f'"{ts_col}" >= ? and "{ts_col}" < ?'
      args = [lo - pad, hi]
      if "deviceId" in present:
        where += ' and "deviceId" = ?'; args.append(device)
      sel = ", ".join(f'"{c}"' if c in present else "null" for c in columns)
      rows = conn.execute(f'select {sel} from "{table}" where {where} order by "{ts_col}"', args).fetchall()
      return rows

    minutes = minute_grid(lo, hi)
    hr_rows = np.array(fetch("hrSample", ["ts", "bpm"]), dtype=np.float64).reshape(-1, 2)
    hr = hr_per_minute(minutes, hr_rows[:, 0], hr_rows[:, 1])
    rr_cols = cols_of("rrInterval")
    rr_rows = np.empty((0, 6))
    if rr_cols:
      sel = ", ".join(f'"{c}"' if c in rr_cols else "null" for c in ("ts", "rrMs", "seq", "srcChannel", "tsSuspect", "ord"))
      where = '"ts" >= ? and "ts" < ?' + (' and "deviceId" = ?' if "deviceId" in rr_cols else "")
      args = [lo, hi] + ([device] if "deviceId" in rr_cols else [])
      # rowid order = insertion order (the tie-break after ts, ord, seq)
      rr_rows = np.array(conn.execute(f'select {sel} from "rrInterval" where {where} order by "ts", rowid', args)
                         .fetchall(), dtype=np.float64).reshape(-1, 6)
    sumsq, pairs, rr_counters = rr_pairs_per_minute(minutes, rr_rows[:, 0], rr_rows[:, 1], rr_rows[:, 2],
                                                     rr_rows[:, 3], rr_rows[:, 4], hr[0], ord_=rr_rows[:, 5])
    g = np.array(fetch("gravitySample", ["ts", "dynAccel"]), dtype=np.float64).reshape(-1, 2)
    motion = grouped_mean_p90(minutes, g[:, 0], g[:, 1])
    st = np.array(fetch("stepSample", ["ts", "counter"], pad=120), dtype=np.float64).reshape(-1, 2)
    steps = steps_per_minute(minutes, st[:, 0], st[:, 1])
    tp = np.array(fetch("skinTempSample", ["ts", "raw"]), dtype=np.float64).reshape(-1, 2)
    temp_raw = mean_per_minute(minutes, tp[:, 0], tp[:, 1])
    sl = np.array(fetch("sleepStateSample", ["ts", "state"]), dtype=np.float64).reshape(-1, 2)
    sleep_frac = mean_per_minute(minutes, sl[:, 0], (sl[:, 1] == 2).astype(np.float64))
    ev = fetch("event", ["ts", "kind"], pad=86400)
    wrist = _wrist_events([(t, k) for t, k in ev if str(k).startswith("WRIST_O")])
    act_rows = []
    if cols_of("activityContextInterval"):
      present = cols_of("activityContextInterval")
      want = ["startTs", "endTs", "activityClass", "confidence", "posture", "sleepState", "wearState", "respRateBpm"]
      sel = ", ".join(f'"{c}"' if c in present else "null" for c in want)
      act_rows = conn.execute(f'select {sel} from "activityContextInterval" where "deviceId" = ? and "endTs" > ? '
                              f'and "startTs" < ? order by "startTs"', (device, lo, hi)).fetchall()
    activity = _activity_dict(act_rows)
    sessions = []
    if cols_of("sleepSession"):
      # Sessions may be stored under a derived id ("<device>-noop"): match the device or a "<device>-" prefix.
      sessions = conn.execute('select "startTs", "endTs" from "sleepSession" where ("deviceId" = ? or "deviceId" like '
                              '? escape \'\\\') and "endTs" > ? and "startTs" < ?',
                              (device, _like_prefix(device) + "-%", lo, hi)).fetchall()
  finally:
    conn.close()
  tl = assemble(minutes, tz_offset_s, device=device, hr=hr, rr=(sumsq, pairs), motion=motion, steps=steps,
                temp_raw=temp_raw, sleep_frac=sleep_frac, wrist=wrist, activity=activity,
                sleep_sessions=[(float(a), float(b)) for a, b in sessions])
  tl.meta.update(source="whoop-sqlite", rr=rr_counters)
  return tl


def _like_prefix(text):
  return str(text).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _activity_dict(rows, with_rank=False):
  keys = ["start", "end", "cls", "conf", "posture", "sleep", "wear", "resp"] + (["rank"] if with_rank else [])
  out = {k: [] for k in keys}
  for r in rows:
    for k, v in zip(keys, r):
      out[k].append(np.nan if (v is None and k in ("conf", "resp", "rank")) else v)
  return out


def load_postgres(db, owner, device, lo, hi, tz_offset_s=0) -> Timeline:
  """Server path. Per-minute aggregation happens in SQL; R-R beats are read one UTC day at a time so a
  120-day timeline never holds every beat in memory. Every query is scoped to (user_id, device_id)."""
  lo = int(lo); hi = int(hi)
  minutes = minute_grid(lo, hi)
  lo = int(minutes[0]); n = len(minutes)
  args = (owner, device, lo, hi)

  def fill(rows, *keys):
    outs = [np.full(n, np.nan) for _ in keys]
    for r in rows:
      i = (int(r["m"]) - lo) // 60
      if 0 <= i < n:
        for o, k in zip(outs, keys):
          if r[k] is not None:
            o[i] = float(r[k])
    return outs

  hr_rows = db.rows(f"""select ts - ts %% 60 as m, avg(bpm)::float8 as mean, max(bpm)::float8 as hi,
      min(bpm)::float8 as lo, count(*)::float8 as n from noop_hr_samples
      where user_id=%s and device_id=%s and ts>=%s and ts<%s and bpm between {HR_RANGE[0]} and {HR_RANGE[1]}
      group by 1""", args)
  mean, mx, mn, cnt = fill(hr_rows, "mean", "hi", "lo", "n")
  cnt = np.nan_to_num(cnt)
  enough = cnt >= MIN_HR_SECONDS
  hr = (np.where(enough, mean, np.nan), np.where(enough, mx, np.nan), np.where(enough, mn, np.nan), cnt)

  sumsq = np.zeros(n); pairs = np.zeros(n); counters = {"input": 0, "clean": 0}
  day = lo - lo % 86400
  while day < hi:
    a, b = max(lo, day), min(hi, day + 86400)
    # ctid order approximates insertion order for these append-only tables (tie-break after ts, ord, seq).
    rows = db.rows("""select ts, "rrMs" as rr, seq, "srcChannel" as ch, "tsSuspect" as sus, ord from noop_rr_intervals
        where user_id=%s and device_id=%s and ts>=%s and ts<%s order by ts, ctid""", (owner, device, a - 5, b))
    if rows:
      arr = np.array([(r["ts"], r["rr"], r["seq"] or 0, -1 if r["ch"] is None else r["ch"],
                       r["sus"] or 0, np.nan if r["ord"] is None else r["ord"]) for r in rows], dtype=np.float64)
      s, p, c = rr_pairs_per_minute(minutes, arr[:, 0], arr[:, 1], arr[:, 2], arr[:, 3], arr[:, 4], hr[0],
                                    ord_=arr[:, 5])
      # Pairs whose later beat precedes this day belong to the previous chunk.
      first = (a - lo) // 60
      s[:first] = 0; p[:first] = 0
      sumsq += s; pairs += p
      counters["input"] += c["input"]; counters["clean"] += c.get("clean", 0)
    day += 86400

  g_rows = db.rows("""select ts - ts %% 60 as m, avg("dynAccel")::float8 as mean,
      percentile_cont(0.9) within group (order by "dynAccel")::float8 as p90 from noop_gravity_samples
      where user_id=%s and device_id=%s and ts>=%s and ts<%s and "dynAccel" is not null group by 1""", args)
  motion = tuple(fill(g_rows, "mean", "p90"))
  s_rows = db.rows("""with s as (select ts, counter, lag(ts) over w as pts, lag(counter) over w as pc
        from noop_step_samples where user_id=%s and device_id=%s and ts>=%s and ts<%s window w as (order by ts))
      select ts - ts %% 60 as m, sum(((counter - pc) %% 65536 + 65536) %% 65536)::float8 as steps,
        bool_or(((counter - pc) %% 65536 + 65536) %% 65536 > 5 * (ts - pts) + 5) as bad
      from s where pts is not null and ts - pts > 0 and ts - pts <= 90 group by 1""", (owner, device, lo - 120, hi))
  steps = np.full(n, np.nan)
  for r in s_rows:
    i = (int(r["m"]) - lo) // 60
    if 0 <= i < n and not r["bad"]:
      steps[i] = float(r["steps"])
  t_rows = db.rows("""select ts - ts %% 60 as m, avg(raw)::float8 as v from noop_skin_temp_samples
      where user_id=%s and device_id=%s and ts>=%s and ts<%s group by 1""", args)
  (temp_raw,) = fill(t_rows, "v")
  sl_rows = db.rows("""select ts - ts %% 60 as m, avg((state = 2)::int)::float8 as v from noop_sleep_state_samples
      where user_id=%s and device_id=%s and ts>=%s and ts<%s group by 1""", args)
  (sleep_frac,) = fill(sl_rows, "v")
  ev_rows = db.rows("""select ts, kind from noop_events where user_id=%s and device_id=%s and ts>=%s and ts<%s
      and kind like 'WRIST_O%%'""", (owner, device, lo - 86400, hi))
  wrist = _wrist_events([(r["ts"], r["kind"]) for r in ev_rows])
  a_rows = db.rows("""select start_ts, end_ts, activity_class, class_confidence::float8 as conf, posture,
      sleep_state, wear_state, source_rank from activity_context_runs
      where user_id=%s and device_id=%s and day between (to_timestamp(%s) at time zone 'UTC')::date - 1
        and (to_timestamp(%s) at time zone 'UTC')::date + 1 and end_ts > %s and start_ts < %s""",
                   (owner, device, lo, hi, lo, hi))
  activity = _activity_dict([(r["start_ts"], r["end_ts"], r["activity_class"], r["conf"], r["posture"],
                              r["sleep_state"], r["wear_state"], None, r["source_rank"]) for r in a_rows],
                            with_rank=True)
  r_rows = db.rows("""select extract(epoch from bucket_start)::bigint as m, avg(value)::float8 as v
      from server_metric_series where user_id=%s and device_id=%s and metric='resp_rate_bpm'
        and bucket_start >= to_timestamp(%s) and bucket_start < to_timestamp(%s) and bucket_seconds <= 60
      group by 1""", args)
  (resp,) = fill([dict(m=int(r["m"]) - int(r["m"]) % 60, v=r["v"]) for r in r_rows], "v")
  nights = db.rows("""select extract(epoch from start_at)::float8 as s, extract(epoch from end_at)::float8 as e
      from server_sleep_nights where user_id=%s and (device_id=%s or device_id is null)
        and end_at > to_timestamp(%s) and start_at < to_timestamp(%s)""", args)
  tl = assemble(minutes, tz_offset_s, device=str(device), hr=hr, rr=(sumsq, pairs), motion=motion, steps=steps,
                temp_raw=temp_raw, sleep_frac=sleep_frac, wrist=wrist, activity=activity, resp=resp,
                sleep_sessions=[(r["s"], r["e"]) for r in nights])
  tl.meta.update(source="postgres", rr=counters)
  return tl
