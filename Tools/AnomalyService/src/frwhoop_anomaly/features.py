"""Minute-level physiology + context + quality for one (user, device, [lo, hi)) span, read from the raw stream
tables by primary-key range and aggregated per minute in SQL.

Channels (targets): hr (bpm), ln_rmssd (ln ms, rolling 5-min), temp (°C), resp (/min, server minute series),
spo2 (%, strap estimate events). Covariates: dyn (g, mean dynamic acceleration), steps (count/min), asleep (0/1).
Quality/context per minute: hr_n (seconds with HR), rr_cov (Σ R-R / 60 s), wrist_off, context ∈
{asleep, still, recovery, walking, active, off, unknown}: from the server activity classifier's 30 s epochs
(activity_context_epochs, confidence ≥ 0.6) where present, else from dynAccel / steps / strap sleep state; then the
steady-state rule. Missing is NaN, never 0.
"""

from __future__ import annotations

import dataclasses
import json

import numpy as np

from . import rr as rrmod

TARGETS = ("hr", "ln_rmssd", "temp", "resp", "spo2")
COVARIATES = ("dyn", "steps", "asleep")

# Thresholds shared with the phone (WatchdogVerifier.WatchdogSignalQuality): moving ≥ 0.05 g, still < 0.05 g.
STILL_DYN = 0.05
ACTIVE_DYN = 0.15
WALK_STEPS = 20
MIN_HR_SECONDS = 30
RECOVERY_AFTER_ACTIVE_MIN = 30
RECOVERY_AFTER_WALKING_MIN = 10
RECOVERY_SETTLE_MIN = 2
EPOCH_MIN_CONFIDENCE = 0.6


@dataclasses.dataclass
class MinuteFrame:
  minutes: np.ndarray                 # (N,) minute start unix
  data: dict[str, np.ndarray]         # name -> (N,)
  context: np.ndarray                 # (N,) str
  family: str | None
  counters: dict

  def targets(self) -> np.ndarray:
    return np.stack([self.data[k] for k in TARGETS])

  def covariates(self) -> np.ndarray:
    return np.stack([self.data[k] for k in COVARIATES])


def steady_state(context: np.ndarray, after_active: int = RECOVERY_AFTER_ACTIVE_MIN,
                 after_walking: int = RECOVERY_AFTER_WALKING_MIN) -> np.ndarray:
  """Still minutes shortly after exertion are "recovery", not rest: HR and HRV are still returning to baseline. Same
  steady-state rule as Layer 1's context strata, which applies it to BOUTS: 30 min after a vigorous bout (≥ 3 active
  minutes), 10 min after a walking bout (≥ 2 exertion minutes), and the 2-minute settle after any shorter movement
  (an isolated arm gesture over the minute-level dyn threshold is not exercise)."""
  out = np.asarray(context, dtype=object).copy()
  n = len(out)
  exert = np.array([c in ("active", "walking") for c in out])
  i = 0
  while i < n:
    if not exert[i]:
      i += 1
      continue
    j = i
    while j + 1 < n and (exert[j + 1] or (j + 2 < n and exert[j + 2])):   # bridge 1-minute gaps
      j += 1
    bout = out[i:j + 1]
    n_active = int(np.sum(bout == "active"))
    length = int(np.sum([c in ("active", "walking") for c in bout]))
    hold = after_active if n_active >= 3 else (after_walking if length >= 2 else RECOVERY_SETTLE_MIN)
    for k in range(j + 1, min(n, j + 1 + hold)):
      if out[k] == "still":
        out[k] = "recovery"
      elif exert[k]:
        break
    i = j + 1
  return out


def epoch_context(minutes: np.ndarray, rows, min_conf: float = EPOCH_MIN_CONFIDENCE) -> list:
  """Per-minute context from activity_context_epochs (None where no confident epoch covers the minute). Both 30 s
  epochs of a minute must agree, else the more cautious label wins (active > walking > recovery > unknown)."""
  by_min: dict[int, list[str]] = {}
  for r in rows:
    if r["conf"] is None or r["conf"] < min_conf:
      continue
    if r["wear_state"] == "off_wrist":
      c = "off"
    elif r["sleep_state"] == "asleep":
      c = "asleep"
    elif r["motion_label"] == "running" or r["exertion_context"] == "active":
      c = "active"
    elif r["motion_label"] in ("walking", "other_movement"):
      c = "walking"
    elif r["exertion_context"] == "post_activity":
      c = "recovery"
    elif r["motion_label"] == "stationary" and r["exertion_context"] in ("resting_candidate", "unknown"):
      c = "still"
    else:
      c = "unknown"
    by_min.setdefault(int(r["start_ts"]) - int(r["start_ts"]) % 60, []).append(c)
  rank = {"off": 6, "active": 5, "walking": 4, "recovery": 3, "unknown": 2, "asleep": 1, "still": 0}
  out = []
  for m in minutes:
    labels = by_min.get(int(m))
    out.append(max(labels, key=rank.__getitem__) if labels else None)
  return out


def _minute_index(lo: int, hi: int) -> np.ndarray:
  lo -= lo % 60
  return np.arange(lo, hi - (hi % 60), 60, dtype=np.int64)


def _fill(minutes: np.ndarray, rows, value_key: str) -> np.ndarray:
  out = np.full(len(minutes), np.nan)
  if not rows:
    return out
  index = {int(m): i for i, m in enumerate(minutes)}
  for r in rows:
    i = index.get(int(r["m"]))
    if i is not None and r[value_key] is not None:
      out[i] = float(r[value_key])
  return out


def device_family(cur, user_id: str, device_id: str) -> str | None:
  cur.execute("select device_family from public.devices where user_id = %s and id = %s", (user_id, device_id))
  r = cur.fetchone()
  return (r or {}).get("device_family")


def load(db, user_id: str, device_id: str, lo: int, hi: int) -> MinuteFrame:
  minutes = _minute_index(lo, hi)
  lo = int(minutes[0]) if len(minutes) else lo
  args = (user_id, device_id, lo, hi)
  with db.read(statement_timeout_ms=45000) as cur:
    family = device_family(cur, user_id, device_id)
    cur.execute("""select ts - ts %% 60 as m, avg(bpm)::float8 as v, count(*)::int as n
                     from public.noop_hr_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    hr_rows = cur.fetchall()
    cur.execute("""select ts, "rrMs" as rr, seq, "srcChannel" as ch, "tsSuspect" as sus
                     from public.noop_rr_intervals
                    where user_id = %s and device_id = %s and ts >= %s and ts < %s""",
                (user_id, device_id, lo - 300, hi))
    rr_rows = cur.fetchall()
    cur.execute("""select ts - ts %% 60 as m, avg(raw)::float8 as v, percentile_cont(0.5) within group (order by raw) as med
                     from public.noop_skin_temp_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    temp_rows = cur.fetchall()
    cur.execute("""select ts - ts %% 60 as m, avg("dynAccel")::float8 as v, count("dynAccel")::int as n
                     from public.noop_gravity_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    dyn_rows = cur.fetchall()
    cur.execute("""select ts - ts %% 60 as m, min(counter) as lo, max(counter) as hi, count(*)::int as n
                     from public.noop_step_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    step_rows = cur.fetchall()
    cur.execute("""select ts - ts %% 60 as m, avg((state = 2)::int)::float8 as v
                     from public.noop_sleep_state_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    sleep_rows = cur.fetchall()
    cur.execute("""select ts, kind, "payloadJSON" as p from public.noop_events
                    where user_id = %s and device_id = %s and ts >= %s and ts < %s
                      and (kind = 'SPO2_STRAP_EST' or kind like 'WRIST_O%%')""",
                (user_id, device_id, lo - 86400, hi))
    event_rows = cur.fetchall()
    cur.execute("""select extract(epoch from bucket_start)::bigint as m, value::float8 as v
                     from public.server_metric_series
                    where user_id = %s and metric = 'resp_rate_bpm' and bucket_seconds = 60
                      and bucket_start >= to_timestamp(%s) and bucket_start < to_timestamp(%s)""",
                (user_id, lo, hi))
    resp_rows = cur.fetchall()
    # The server's activity classifier (HART / streams, 30 s epochs; latest revision per epoch) is the primary
    # context source: the same ontology the phone's activity context uses.
    cur.execute("""select distinct on (start_ts) start_ts, motion_label, sleep_state, exertion_context, wear_state,
                          confidence::float8 as conf
                     from public.activity_context_epochs
                    where user_id = %s and device_id = %s
                      and day between (to_timestamp(%s) at time zone 'UTC')::date - 1
                                  and (to_timestamp(%s) at time zone 'UTC')::date + 1
                      and start_ts >= %s and start_ts < %s
                    order by start_ts, computed_at desc""", (user_id, device_id, lo, hi, lo, hi))
    epoch_rows = cur.fetchall()

  counters: dict = {}
  hr = _fill(minutes, hr_rows, "v")
  hr_n = _fill(minutes, hr_rows, "n")
  hr_n = np.where(np.isnan(hr_n), 0, hr_n)
  hr_at = {int(m): v for m, v in zip(minutes, hr) if np.isfinite(v)}
  ts, rrv, c = rrmod.clean_beats([(r["ts"], r["rr"], r["seq"] or 0, r["ch"], r["sus"]) for r in rr_rows], hr_at)
  counters["rr"] = c
  rmssd, rr_cov = rrmod.rmssd_per_minute(ts, rrv, minutes)
  ln_rmssd = np.where(rmssd > 0, np.log(np.where(rmssd > 0, rmssd, 1)), np.nan)

  # Skin temperature: WHOOP 5/MG = centidegrees; WHOOP 4.0 = raw ADC → 33 °C + 0.05 °C × (raw − device anchor)
  # (WhoopProtocol Whoop4SkinTemp). Family from the device row, else from the value range.
  raw = _fill(minutes, temp_rows, "v")
  fam = (family or "").lower()
  finite = raw[np.isfinite(raw)]
  if "4" in fam or (not fam and len(finite) and np.nanmedian(finite) < 2500):
    in_band = finite[(finite >= 550) & (finite <= 2040)]
    anchor = float(np.median(in_band)) if len(in_band) >= 100 else 826.0
    temp = 33.0 + 0.05 * (raw - anchor)
    counters["temp_mapping"] = "whoop4-anchor"
  else:
    temp = raw / 100.0
    counters["temp_mapping"] = "centidegree"
  temp = np.where((temp >= 25) & (temp <= 42), temp, np.nan)

  dyn = _fill(minutes, dyn_rows, "v")
  steps = np.full(len(minutes), np.nan)
  index = {int(m): i for i, m in enumerate(minutes)}
  for r in step_rows:
    i = index.get(int(r["m"]))
    if i is not None and r["lo"] is not None:
      d = (int(r["hi"]) - int(r["lo"])) % 65536
      steps[i] = float(d) if d < 400 else np.nan
  asleep = _fill(minutes, sleep_rows, "v")
  asleep = np.where(np.isfinite(asleep), (asleep >= 0.5).astype(float), np.nan)

  spo2 = np.full(len(minutes), np.nan)
  sp_acc: dict[int, list[float]] = {}
  wrist: list[tuple[int, bool]] = []
  for e in event_rows:
    if e["kind"] == "SPO2_STRAP_EST":
      try:
        pct = float(json.loads(e["p"] or "{}").get("pct"))
      except (TypeError, ValueError, json.JSONDecodeError):
        continue
      if 70 <= pct <= 100:
        sp_acc.setdefault(int(e["ts"]) - int(e["ts"]) % 60, []).append(pct)
    elif str(e["kind"]).startswith("WRIST_ON"):
      wrist.append((int(e["ts"]), True))
    elif str(e["kind"]).startswith("WRIST_OFF"):
      wrist.append((int(e["ts"]), False))
  for m, vals in sp_acc.items():
    i = index.get(m)
    if i is not None:
      spo2[i] = float(np.median(vals))
  resp = _fill(minutes, resp_rows, "v")
  resp = np.where((resp >= 4) & (resp <= 40), resp, np.nan)

  wrist.sort()
  wrist_off = np.zeros(len(minutes), dtype=bool)
  for i, m in enumerate(minutes):
    last = [w for w in wrist if w[0] <= m + 60]
    if last and not last[-1][1]:
      wrist_off[i] = True

  context = np.empty(len(minutes), dtype=object)
  for i in range(len(minutes)):
    if wrist_off[i] or hr_n[i] < MIN_HR_SECONDS:
      context[i] = "off" if wrist_off[i] else "unknown"
    elif asleep[i] == 1:
      context[i] = "asleep"
    elif np.isfinite(steps[i]) and steps[i] >= WALK_STEPS:
      context[i] = "active" if (np.isfinite(dyn[i]) and dyn[i] >= ACTIVE_DYN) else "walking"
    elif np.isfinite(dyn[i]) and dyn[i] >= ACTIVE_DYN:
      context[i] = "active"
    elif np.isfinite(dyn[i]) and dyn[i] < STILL_DYN and (not np.isfinite(steps[i]) or steps[i] == 0):
      context[i] = "still"
    else:
      context[i] = "unknown"

  epoch_ctx = epoch_context(minutes, epoch_rows)
  counters["context_from_epochs"] = int(sum(1 for c in epoch_ctx if c is not None))
  for i, c in enumerate(epoch_ctx):
    if c is not None and context[i] not in ("off",) and not (c != "off" and hr_n[i] < MIN_HR_SECONDS):
      context[i] = c
  context = steady_state(context)

  data = {
    "hr": np.where(hr_n >= MIN_HR_SECONDS, hr, np.nan),
    "ln_rmssd": ln_rmssd,
    "temp": temp,
    "resp": resp,
    "spo2": spo2,
    "dyn": dyn,
    "steps": steps,
    "asleep": asleep,
    "hr_n": hr_n,
    "rr_cov": rr_cov,
    "wrist_off": wrist_off.astype(float),
  }
  return MinuteFrame(minutes=minutes, data=data, context=context, family=family, counters=counters)
