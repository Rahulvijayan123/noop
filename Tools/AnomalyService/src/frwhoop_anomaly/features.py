"""Minute-level physiology + context + quality for one (user, device, [lo, hi)) span, read from the raw stream
tables by primary-key range and aggregated per minute in SQL.

Channels (targets): hr (bpm), ln_rmssd (ln ms, rolling 5-min), temp (°C), resp (/min, server minute series),
spo2 (%, strap estimate events). Covariates: dyn (g, mean dynamic acceleration), steps (count/min), asleep (0/1).
Quality/context per minute: hr_n (seconds with HR), rr_cov (Σ R-R / 60 s), wrist_off, link_down (share of the minute
the strap reported its BLE link down; the strap banks those samples, so this is display-only), contact_lost (1 when
the latest standard-HR contact state says "supported, not detected", 0 when detected, NaN when unknown), context ∈
{asleep, still, recovery, walking, active, off, unknown}: from dynAccel / steps / strap sleep state, refined by the
server activity classifier's 30 s epochs (the CURRENT lineage, activity_context_epochs_current, confidence ≥ 0.6)
only toward caution (an epoch never turns a minute with dynAccel ≥ 0.05 g or steps into still); then the
steady-state rule. Movement evidence for rule exercise-session-2 (exercise_session.py): walk_frac (share of the
minute's step samples the strap classed walk/run), ep_strong (confident epochs: walking/running/active or a logged
exercise). An other_movement epoch is not evidence (it covers gym and other awake minutes alike); it still refines a
minute's context toward caution. Missing is NaN, never 0.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import json
import statistics
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import numpy as np

from . import exercise_session as es
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
# Rule exercise-session-2 evidence thresholds (docs/context-watchdog/EXERCISE_SESSION.md).
STRONG_DYN = 0.10
WEAK_DYN = STILL_DYN
WALK_FRAC_STRONG = 0.5
# Caution order for merging a minute's labels: a later label never moves a minute DOWN this order except between
# the two restful labels (an epoch may say asleep where the strap says still, and vice versa).
CAUTION = {"still": 0, "asleep": 1, "unknown": 2, "recovery": 3, "walking": 4, "active": 5, "off": 6}
RESTFUL = ("still", "asleep")


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
  out = []
  for m in minutes:
    labels = by_min.get(int(m))
    out.append(max(labels, key=CAUTION.__getitem__) if labels else None)
  return out


def epoch_evidence(minutes: np.ndarray, rows, min_conf: float = EPOCH_MIN_CONFIDENCE) -> np.ndarray:
  """Per-minute strong movement evidence from confident epochs (rule exercise-session-2): 1 when an epoch of the
  minute is walking / running, exertion "active", or inside a logged exercise session, else 0. NaN where no
  confident epoch covers the minute; off-wrist and asleep epochs are never evidence. Epochs give no weak evidence:
  other_movement covers 27 % of gym minutes and 29 % of other awake minutes (EXERCISE_SESSION.md)."""
  strong = np.full(len(minutes), np.nan)
  index = {int(m): i for i, m in enumerate(minutes)}
  for r in rows:
    if r["conf"] is None or r["conf"] < min_conf:
      continue
    i = index.get(int(r["start_ts"]) - int(r["start_ts"]) % 60)
    if i is None:
      continue
    if r["wear_state"] == "off_wrist" or r["sleep_state"] == "asleep":
      s = 0.0
    else:
      s = float(r["motion_label"] in ("walking", "running") or r["exertion_context"] == "active"
                or r.get("exercise_session") == "true")
    strong[i] = max(s, 0.0 if np.isnan(strong[i]) else strong[i])
  return strong


def base_context(dyn: np.ndarray, steps: np.ndarray, asleep: np.ndarray, wrist_off: np.ndarray,
                 hr_n: np.ndarray) -> np.ndarray:
  """Context from the strap's own streams (dynAccel, step counter, sleep state, wrist events). A minute with no
  data at all (NaN everywhere, e.g. a gap the minute cache filled) is "unknown", never "off"."""
  dyn, steps, asleep = (np.asarray(x, dtype=np.float64) for x in (dyn, steps, asleep))
  off = np.nan_to_num(np.asarray(wrist_off, dtype=np.float64)) > 0
  with np.errstate(invalid="ignore"):
    no_hr = np.asarray(hr_n, dtype=np.float64) < MIN_HR_SECONDS
    walk = np.isfinite(steps) & (steps >= WALK_STEPS)
    vigorous = np.isfinite(dyn) & (dyn >= ACTIVE_DYN)
    still = np.isfinite(dyn) & (dyn < STILL_DYN) & (~np.isfinite(steps) | (steps == 0))
    sleeping = asleep == 1
  ctx = np.select([off, no_hr, sleeping, walk & vigorous, walk, vigorous, still],
                  ["off", "unknown", "asleep", "active", "walking", "active", "still"], default="unknown")
  return ctx.astype(object)


def recontext(frame: MinuteFrame) -> MinuteFrame:
  """Re-derive each minute's context under the current hygiene from the frame's own channels, with the STORED label
  in the role of the classifier's label: a minute cached before the fix, whose classifier label overrode movement
  (dynAccel ≥ 0.05 g or steps → still), becomes "unknown" again; labels that were already cautious stay. Idempotent
  on frames that features.load built (so the service can apply it to its whole minute cache every job)."""
  d = frame.data
  n = len(frame.minutes)
  nan = np.full(n, np.nan)
  dyn, steps, hr_n = d.get("dyn", nan), d.get("steps", nan), d.get("hr_n", nan)
  base = base_context(dyn, steps, d.get("asleep", nan), d.get("wrist_off", nan), hr_n)
  stored = [c if c in CAUTION else None for c in np.asarray(frame.context).astype(str)]
  ctx = steady_state(merge_epoch_context(base, stored, dyn, steps, np.nan_to_num(np.asarray(hr_n, dtype=float))))
  return MinuteFrame(minutes=frame.minutes, data=frame.data, context=ctx, family=frame.family,
                     counters=frame.counters)


def merge_epoch_context(base: np.ndarray, epoch: list, dyn: np.ndarray, steps: np.ndarray,
                        hr_n: np.ndarray) -> np.ndarray:
  """Epoch labels refine the strap's context only toward caution. An epoch may (a) raise a minute up the CAUTION
  order (still → recovery / walking / active / off), (b) choose between the two restful labels, and (c) label a
  minute the strap streams could not (no motion data). It never turns a minute that MOVED (dynAccel ≥ 0.05 g or a
  step-counter increment) into still or asleep: the wrist classifier reads resistance training between sets as
  stationary, and those minutes must not reach a rest reference. Off stays off; a minute without heart rate keeps
  its label unless the epoch says off-wrist."""
  out = np.asarray(base, dtype=object).copy()
  with np.errstate(invalid="ignore"):
    moved = (np.isfinite(dyn) & (dyn >= STILL_DYN)) | (np.isfinite(steps) & (steps > 0))
  for i, c in enumerate(epoch):
    b = out[i]
    if c is None or b == "off" or (c != "off" and hr_n[i] < MIN_HR_SECONDS):
      continue
    if c in RESTFUL:
      if not moved[i] and (b in RESTFUL or b == "unknown"):
        out[i] = c
    elif CAUTION[c] > CAUTION[b]:
      out[i] = c
  return out


def link_down_share(minutes: np.ndarray, events: list[tuple[int, bool]]) -> np.ndarray:
  """Share of each minute the strap reported its BLE link down (events: (ts, up?) in time order). The strap
  banks samples while the link is down (canonical strap_link_down: display only)."""
  out = np.zeros(len(minutes))
  if not events or not len(minutes):
    return out
  spans, down_at = [], None
  for ts, up in events:
    if not up and down_at is None:
      down_at = ts
    elif up and down_at is not None:
      spans.append((down_at, ts))
      down_at = None
  if down_at is not None:
    spans.append((down_at, int(minutes[-1]) + 60))
  m0, m1 = int(minutes[0]), int(minutes[-1]) + 60
  for a, b in spans:
    lo, hi = max(a, m0), min(b, m1)
    if hi <= lo:
      continue
    for k in range((lo - m0) // 60, (hi - 1 - m0) // 60 + 1):
      s = m0 + 60 * k
      out[k] += (min(hi, s + 60) - max(lo, s)) / 60.0
  return np.minimum(out, 1.0)


def contact_state(minutes: np.ndarray, events: list[tuple[int, str]]) -> np.ndarray:
  """1 when the latest standard-HR contact state at or before the minute's end is supported_not_detected, 0 when
  supported_detected, NaN when unsupported or never reported (contact is a state; only changes are stored)."""
  out = np.full(len(minutes), np.nan)
  if not events:
    return out
  ts = np.array([e[0] for e in events], dtype=np.int64)
  val = np.array([1.0 if e[1] == "supported_not_detected" else 0.0 if e[1] == "supported_detected" else np.nan
                  for e in events])
  j = np.searchsorted(ts, np.asarray(minutes, dtype=np.int64) + 60, side="right") - 1
  ok = j >= 0
  out[ok] = val[j[ok]]
  return out


# ---- per-user context the job reads once: time zone history and nightly resting heart rate ----------------------

def timezone_history(db, user_id: str) -> list[tuple[float, str]]:
  """[(effective_at unix, IANA zone)] oldest first: scoring_timezone_history (the zones the person's days were
  scored in, DST handled by the zone), else profiles.timezone, else UTC. Unknown zone names fall back to UTC."""
  with db.read() as cur:
    cur.execute("""select extract(epoch from effective_at)::float8 as at, timezone_id as tz
                     from public.scoring_timezone_history where user_id = %s order by effective_at""", (user_id,))
    rows = [(float(r["at"]), str(r["tz"])) for r in cur.fetchall()]
    if not rows:
      cur.execute("select timezone as tz from public.profiles where id = %s", (user_id,))
      r = cur.fetchone()
      rows = [(float("-inf"), str(r["tz"]))] if r and r.get("tz") else []
  return [(at, tz if _zone(tz) is not None else "UTC") for at, tz in rows] or [(float("-inf"), "UTC")]


def _zone(name: str) -> ZoneInfo | None:
  try:
    return ZoneInfo(name)
  except (ZoneInfoNotFoundError, ValueError):
    return None


def zone_at(history: list[tuple[float, str]] | None, ts: float) -> ZoneInfo:
  name = "UTC"
  for at, tz in history or ():
    if at <= ts:
      name = tz
    else:
      break
  return _zone(name) or ZoneInfo("UTC")


def local_day(ts: float, history: list[tuple[float, str]] | None) -> str:
  """The person's local calendar day of instant `ts`, in the zone effective at `ts` (DST-correct)."""
  return dt.datetime.fromtimestamp(ts, tz=zone_at(history, ts)).date().isoformat()


RESTING_NIGHTS = 14
RESTING_LOOKBACK_DAYS = 60


def resting_nights(db, user_id: str, until_day: str) -> list[tuple[str, float]]:
  """Nightly resting heart rate (server_daily_scores, frwhoop-server-1), (day, bpm) oldest first, for the
  RESTING_LOOKBACK_DAYS before `until_day` (inclusive) — the same source the worker's decoder config reads."""
  with db.read() as cur:
    cur.execute("""select day::text as d, resting_hr_bpm::float8 as r from public.server_daily_scores
                    where user_id = %s and algorithm_version = 'frwhoop-server-1' and resting_hr_bpm is not null
                      and day <= %s::date and day > %s::date - %s
                    order by day""", (user_id, until_day, until_day, RESTING_LOOKBACK_DAYS))
    return [(r["d"], float(r["r"])) for r in cur.fetchall()]


def sleep_rest_reference(nights: list[tuple[str, float]] | None, day: str) -> float | None:
  """Median nightly resting HR of the (at most RESTING_NIGHTS) nights before local `day`, or None."""
  vals = [r for d, r in (nights or ()) if d < day and 30 <= r <= 120][-RESTING_NIGHTS:]
  return float(statistics.median(vals)) if vals else None


# ---- rule exercise-session-2 over the minute frame ----------------------------------------------------------------

EXERCISE = "exercise"
EXERCISE_RECOVERY = "exercise_recovery"
# A period that met the session conditions but is not confirmed (phase `active`): never rest, no recovery after it,
# and no exercise label (it trains no exercise reference). Windows touching it are withheld as "activity".
EXERCISE_ACTIVE = "exercise_active"
PRE_REST_WINDOW_MIN = 120
DEFAULT_REST_BPM = es.DEFAULT_REST_BPM


def exertion_evidence(frame: MinuteFrame) -> tuple[np.ndarray, np.ndarray]:
  """Per-minute HR-free evidence (EXERCISE_SESSION.md): strong = walk/run step classes on ≥ half the minute's step
  samples, dynAccel ≥ 0.10 g, or a confident walking / running / active / logged-exercise epoch; weak = dynAccel
  ≥ 0.05 g. Off-wrist and asleep minutes are never evidence. A frame cached before these channels existed has NaN
  there, which is no evidence (dynAccel still counts). The `ep_weak` channel (other_movement epochs, rule -1) that a
  frame cached before rule -2 still carries is not read."""
  n = len(frame.minutes)
  nan = np.full(n, np.nan)
  d = frame.data
  dyn, walk, eps = d.get("dyn", nan), d.get("walk_frac", nan), d.get("ep_strong", nan)
  with np.errstate(invalid="ignore"):
    ok = ~(np.nan_to_num(d.get("wrist_off", nan)) > 0) & ~(d.get("asleep", nan) == 1)
    strong = ok & ((walk >= WALK_FRAC_STRONG) | (dyn >= STRONG_DYN) | (eps == 1))
    weak = ok & (dyn >= WEAK_DYN)
  return strong, weak


def with_sessions(frame: MinuteFrame, sleep_rest=None, live: bool = True) -> tuple[MinuteFrame, list[dict]]:
  """The frame with rule exercise-session-2 applied: every minute of a confirmed session becomes EXERCISE and every
  minute of its recovery EXERCISE_RECOVERY; every minute of a period that met the session conditions but is not
  confirmed becomes EXERCISE_ACTIVE, with no recovery after it (off-wrist minutes stay "off"). None of them can
  count as rest or sleep, and only EXERCISE is exercise. Returns the new frame (data shared, context copied) and the
  sessions as unix spans with `confirmed` / `confirmed_at` (unix, None when unconfirmed).

  Rest reference per period (EXERCISE_SESSION.md order; the server has no established awake-rest centre):
  `sleep_rest(unix)` + 10 (the nightly resting HR of the nights before), else the median HR of the still, awake
  minutes in the 2 h before the period, else 70 bpm. With `live`, a period still open at the frame's end (newest
  evidence ≤ 10 min old) counts once conditions 1–3 hold, as on the phone; its duration is checked when it ends. An
  open period covers the minutes up to the frame's end, confirmed or not (live opening is unchanged); it is
  confirmed by its strong minutes so far (or inherited) and otherwise stays EXERCISE_ACTIVE."""
  n = len(frame.minutes)
  if n == 0:
    return frame, []
  t0 = int(frame.minutes[0])
  pos = ((np.asarray(frame.minutes, dtype=np.int64) - t0) // 60).astype(np.int64)
  size = int(pos[-1]) + 1
  strong_f, weak_f = exertion_evidence(frame)
  hr_f = frame.data["hr"]
  ctx_f = np.asarray(frame.context, dtype=object)
  def grid(values, fill):
    out = np.full(size, fill, dtype=np.asarray(values).dtype)
    out[pos] = values
    return out
  hr = [h if h == h else None for h in grid(np.asarray(hr_f, dtype=np.float64), np.nan).tolist()]
  strong, weak = grid(strong_f, False).tolist(), grid(weak_f, False).tolist()
  still = grid(ctx_f == "still", False).tolist()

  def rest(a: int) -> float:
    r = sleep_rest(t0 + a * 60) if sleep_rest is not None else None
    if r is not None:
      return float(r) + 10.0
    vals = [hr[i] for i in range(max(0, a - PRE_REST_WINDOW_MIN), a) if still[i] and hr[i] is not None]
    return float(statistics.median(vals)) if vals else DEFAULT_REST_BPM

  spans = [dict(s, open=False) for s in es.session_spans(hr, strong, weak, rest)]
  if live:
    # The last period is still open while its newest evidence is at most MERGE_GAP_MIN minutes old. Unconfirmed, it
    # covers the minutes up to now itself (it has no recovery to cover them).
    for s in spans[-1:]:
      if size - 1 - s["b"] <= es.MERGE_GAP_MIN:
        s["open"] = True
        if not s["confirmed"]:
          s.update(b=size - 1, end=size)
    ev = es.anchored(strong, weak)
    tail = es.periods(ev)[-1:] if any(ev) else []
    for a, b in tail:
      covered = any(s["a"] <= a <= s["b"] for s in spans)
      if not covered and size - 1 - b <= es.MERGE_GAP_MIN:
        r = rest(a)
        cs = np.concatenate([[0], np.cumsum(ev[a:b + 1])])
        dense = any(cs[min(s + es.SPAN_MIN, b - a + 1)] - cs[s] >= es.MIN_EVIDENCE_IN_SPAN for s in range(b - a + 1))
        n_strong = sum(strong[a:b + 1])
        load = sum(1 for i in range(a, b + 1) if hr[i] is not None and hr[i] >= r + es.LOAD_DELTA_BPM)
        if dense and n_strong >= es.MIN_STRONG and load >= es.MIN_LOAD_MIN:
          last_confirmed = max((s["b"] for s in spans if s["confirmed"]), default=None)
          at = es.confirmation(a, b, strong, last_confirmed)
          spans.append({"a": a, "b": size - 1, "end": size, "pre": None, "rest": r, "open": True,
                        "confirmed": at is not None, "confirmed_at": at})
  phase = np.zeros(size, dtype=np.int8)           # 0 none, 1 session, 2 recovery, 3 active (unconfirmed)
  for s in spans:
    if s["confirmed"]:
      phase[s["b"] + 1:s["end"]] = np.where(phase[s["b"] + 1:s["end"]] == 0, 2, phase[s["b"] + 1:s["end"]])
    phase[s["a"]:s["b"] + 1] = 1 if s["confirmed"] else 3
  ctx = ctx_f.copy()
  p = phase[pos]
  ctx[(p == 1) & (ctx_f != "off")] = EXERCISE
  ctx[(p == 2) & (ctx_f != "off")] = EXERCISE_RECOVERY
  ctx[(p == 3) & (ctx_f != "off")] = EXERCISE_ACTIVE
  out = [{"start": t0 + s["a"] * 60, "end": t0 + s["b"] * 60, "recovery_end": t0 + s["end"] * 60,
          "open": s["open"], "confirmed": bool(s["confirmed"]),
          "confirmed_at": None if s["confirmed_at"] is None else t0 + s["confirmed_at"] * 60,
          "rest_reference": round(float(s["rest"]), 1),
          "pre_reference": None if s["pre"] is None else round(float(s["pre"]), 1)} for s in spans]
  return MinuteFrame(minutes=frame.minutes, data=frame.data, context=ctx, family=frame.family,
                     counters=dict(frame.counters)), out


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
    cur.execute("""select ts - ts %% 60 as m, min(counter) as lo, max(counter) as hi, count(*)::int as n,
                          count(*) filter (where "activityClass" in (1, 2))::int as walk
                     from public.noop_step_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    step_rows = cur.fetchall()
    cur.execute("""select ts - ts %% 60 as m, avg((state = 2)::int)::float8 as v
                     from public.noop_sleep_state_samples where user_id = %s and device_id = %s and ts >= %s and ts < %s
                    group by 1""", args)
    sleep_rows = cur.fetchall()
    cur.execute("""select ts, kind, "payloadJSON" as p from public.noop_events
                    where user_id = %s and device_id = %s and ts >= %s and ts < %s
                      and (kind = 'SPO2_STRAP_EST' or kind like 'WRIST_O%%' or kind like 'BLE_CONNECTION_%%'
                           or kind = 'STANDARD_HR_CONTACT')""",
                (user_id, device_id, lo - 86400, hi))
    event_rows = cur.fetchall()
    cur.execute("""select extract(epoch from bucket_start)::bigint as m, value::float8 as v
                     from public.server_metric_series
                    where user_id = %s and metric = 'resp_rate_bpm' and bucket_seconds = 60
                      and bucket_start >= to_timestamp(%s) and bucket_start < to_timestamp(%s)""",
                (user_id, lo, hi))
    resp_rows = cur.fetchall()
    # The server's activity classifier (HART / streams, 30 s epochs): only the CURRENT lineage of each UTC day
    # (activity_context_epochs_current = the newest publish of the day, the rule DayScoring reads). The table keeps
    # every superseded lineage for causal replay; reading across them let a stale lineage's label win a slot.
    cur.execute("""select start_ts, motion_label, sleep_state, exertion_context, wear_state, exercise_session,
                          confidence::float8 as conf
                     from public.activity_context_epochs_current
                    where user_id = %s and device_id = %s
                      and day between (to_timestamp(%s) at time zone 'UTC')::date - 1
                                  and (to_timestamp(%s) at time zone 'UTC')::date + 1
                      and start_ts >= %s and start_ts < %s
                    order by start_ts""", (user_id, device_id, lo, hi, lo, hi))
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
  walk_frac = np.full(len(minutes), np.nan)
  index = {int(m): i for i, m in enumerate(minutes)}
  for r in step_rows:
    i = index.get(int(r["m"]))
    if i is not None and r["lo"] is not None:
      d = (int(r["hi"]) - int(r["lo"])) % 65536
      steps[i] = float(d) if d < 400 else np.nan
    if i is not None and r.get("n"):
      walk_frac[i] = float(r.get("walk") or 0) / float(r["n"])
  asleep = _fill(minutes, sleep_rows, "v")
  asleep = np.where(np.isfinite(asleep), (asleep >= 0.5).astype(float), np.nan)

  spo2 = np.full(len(minutes), np.nan)
  sp_acc: dict[int, list[float]] = {}
  wrist: list[tuple[int, bool]] = []
  link: list[tuple[int, bool]] = []
  contact: list[tuple[int, str]] = []
  for e in sorted(event_rows, key=lambda e: int(e["ts"])):
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
    elif str(e["kind"]).startswith("BLE_CONNECTION_UP"):
      link.append((int(e["ts"]), True))
    elif str(e["kind"]).startswith("BLE_CONNECTION_DOWN"):
      link.append((int(e["ts"]), False))
    elif e["kind"] == "STANDARD_HR_CONTACT":
      try:
        contact.append((int(e["ts"]), str(json.loads(e["p"] or "{}").get("contact"))))
      except (TypeError, ValueError, json.JSONDecodeError, AttributeError):
        continue
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

  context = base_context(dyn, steps, asleep, wrist_off, hr_n)
  epoch_ctx = epoch_context(minutes, epoch_rows)
  counters["context_from_epochs"] = int(sum(1 for c in epoch_ctx if c is not None))
  merged = merge_epoch_context(context, epoch_ctx, dyn, steps, hr_n)
  # Minutes an epoch called still/asleep that moved: they used to be relabelled restful.
  with np.errstate(invalid="ignore"):
    moved = (np.isfinite(dyn) & (dyn >= STILL_DYN)) | (np.isfinite(steps) & (steps > 0))
  counters["epoch_restful_refused"] = int(sum(1 for i, c in enumerate(epoch_ctx) if c in RESTFUL and moved[i]))
  context = steady_state(merged)
  ep_strong = epoch_evidence(minutes, epoch_rows)

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
    "walk_frac": walk_frac,
    "ep_strong": ep_strong,
    "link_down": link_down_share(minutes, link),
    "contact_lost": contact_state(minutes, contact),
  }
  return MinuteFrame(minutes=minutes, data=data, context=context, family=family, counters=counters)
