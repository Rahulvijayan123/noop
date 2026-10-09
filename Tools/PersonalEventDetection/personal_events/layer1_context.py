"""The phone's Layer 1 v2 context-strata baselines, ported for the signature engine (`layer1` normalisation).

What the Watchdog draws for every minute is the person's own Layer 1 reference for that minute's context: sleep HR
while asleep; awake still by posture (supine / seated / upright, falling back to pooled awake rest); steady walking HR.
HRV uses the awake ln(RMSSD) strata. This module reproduces that expectation from the phone's stored activity-context
intervals (`activityContextInterval`), faithfully to the Swift:

* daily stratum values: `LongitudinalBaseline.ContextMaterializer.observations`
  (Packages/StrandAnalytics/Sources/StrandAnalytics/LongitudinalBaselineContext.swift:36-249) with the range check of
  `LongitudinalBaseline.observation` and the coverage gate `applyCoverageGate` (LongitudinalBaseline.swift:1901-1990);
* the daily reference: `LongitudinalBaseline.evaluate` with replay (T-60 ... T-8 window, median, small-sample MAD with
  trim, AR(1) n_eff with Kendall bias correction, Student-t predictive scale, shown from 4 days, established at 14,
  stale after 14 days) - NOT re-implemented here: the window statistics are Tools/MetricInsight's `layer1.py` port,
  which is pinned to the same Swift (`_score_one_day`, `_window_copy`, `observation`, `_median`, ...);
  `withinDayScaleLong` (LongitudinalBaseline.swift:1843-1846) is computed here because layer1.py covers nightly
  series only;
* the per-minute reference: `WatchdogLiveReferences.series / lookup` (WatchdogVerifier.swift:224-268),
  `WatchdogExpectation.settling / track` (WatchdogExpectation.swift:40-84) and the floors of
  `WatchdogExpectation.residual` (`WatchdogConfig.hrScale` 5 bpm, `hrvScale` 8 ms);
* minute context transitions and time since effort / walking: `WatchdogContextResolver.resolve`
  (WatchdogVerifier.swift:195-206).

Causal: a minute on local day D uses the evaluation as of D built only from days before D (the phone's evaluation of
day D may also see D's own partial value, which only moves the staleness clock). No stand-in: where the Swift would
draw nothing the expectation is NaN. Provisional references (shown, 4-13 days; the Watchdog never draws them) are
returned flagged `provisional`.

Pinned to the Swift by tests/data/layer1_context_expected.json, recorded by
Packages/StrandAnalytics/Tests/StrandAnalyticsTests/LayerOneContextMirrorTests.swift for the synthetic tapes of
scripts/make_layer1_context_cases.py (tests/test_layer1_context.py).
"""
from __future__ import annotations

import dataclasses
import importlib.util
import math
import os
import sys
from pathlib import Path

import numpy as np

UNAVAILABLE_SERVER = "personal context baselines are computed on the phone and not yet available to the server"

# --------------------------------------------------------------------------------------------- shared statistics


def load_layer1():
  """Tools/MetricInsight's Layer 1 port (`nara_metric_insight.layer1`). It is stdlib-only, so it is imported when the
  package is installed, else loaded from its file in this repository (or $NARA_LAYER1_PY) without importing the rest
  of the metric-insight worker (whose pins - Python 3.12, psycopg 3.2.10 - would conflict with this package's).
  Returns None when it cannot be found (the `layer1` normalisation then abstains)."""
  cached = sys.modules.get("nara_metric_insight.layer1") or sys.modules.get("_nara_layer1")
  if cached is not None:
    return cached
  try:
    from nara_metric_insight import layer1  # type: ignore
    return layer1
  except ImportError:
    pass
  path = os.environ.get("NARA_LAYER1_PY") or str(
    Path(__file__).resolve().parents[2] / "MetricInsight" / "src" / "nara_metric_insight" / "layer1.py")
  if not os.path.isfile(path):
    return None
  spec = importlib.util.spec_from_file_location("_nara_layer1", path)
  module = importlib.util.module_from_spec(spec)
  sys.modules["_nara_layer1"] = module   # dataclasses resolve their module through sys.modules
  try:
    spec.loader.exec_module(module)
  except Exception:
    del sys.modules["_nara_layer1"]
    raise
  return module


# --------------------------------------------------------------------------------------------- series

@dataclasses.dataclass(frozen=True)
class SeriesDef:
  key: str
  channel: str          # "hr" | "hrv"
  min_val: float        # LongitudinalBaseline.seriesSpec
  max_val: float
  floor: float          # math scale (ln for HRV)
  k_band: float         # params(for:)
  span7: int
  n_established: int
  coverage_need: float  # applyCoverageGate (minutes; HRV: clean beat pairs / 60)
  coverage_required: bool   # awake rest: no coverage -> low quality

  @property
  def uses_log(self):
    return self.channel == "hrv"


def _hr(key, lo, hi, floor, k, need, required=False):
  return SeriesDef(key, "hr", lo, hi, floor, k, 7, 14, need, required)


def _hrv(key, need, required=False):
  return SeriesDef(key, "hrv", 5, 250, 0.08, 2.6, 10, 14, need, required)


# Params: postureMinMinutes 15, walkingMinMinutes 10, sleepHRMinMinutes 120, awakeRestMinStill 30.
SERIES = {s.key: s for s in (
  _hr("sleep_hr", 30, 130, 2, 2.0, 120),
  _hr("awake_rest_hr", 35, 160, 3, 2.0, 30, True),
  _hrv("awake_rest_hrv_ln", 30, True),
  _hr("awake_supine_hr", 35, 160, 3, 2.0, 15),
  _hrv("awake_supine_hrv_ln", 15),
  _hr("awake_seated_hr", 35, 160, 3, 2.0, 15),
  _hrv("awake_seated_hrv_ln", 15),
  _hr("awake_upright_hr", 35, 160, 3, 2.0, 15),
  _hrv("awake_upright_hrv_ln", 15),
  _hr("walking_hr", 50, 190, 4, 2.2, 10),
)}
SERIES_KEYS = tuple(SERIES)
# Human names of the strata (LBSeries.planRow), for reports.
STRATUM_NAMES = {"sleep_hr": "asleep", "awake_rest_hr": "awake rest", "awake_rest_hrv_ln": "awake rest",
                 "awake_supine_hr": "lying", "awake_supine_hrv_ln": "lying", "awake_seated_hr": "seated",
                 "awake_seated_hrv_ln": "seated", "awake_upright_hr": "standing", "awake_upright_hrv_ln": "standing",
                 "walking_hr": "steady walking"}

# WatchdogLiveReferences.series(kind:posture:channel:)
_HR_SERIES = {("asleep", None): ("sleep_hr",), ("walking", None): ("walking_hr",),
              ("awake_still", None): ("awake_rest_hr",),
              ("awake_still", "supine"): ("awake_supine_hr", "awake_rest_hr"),
              ("awake_still", "seated"): ("awake_seated_hr", "awake_rest_hr"),
              ("awake_still", "upright"): ("awake_upright_hr", "awake_rest_hr")}
_HRV_SERIES = {("awake_still", None): ("awake_rest_hrv_ln",),
               ("awake_still", "supine"): ("awake_supine_hrv_ln", "awake_rest_hrv_ln"),
               ("awake_still", "seated"): ("awake_seated_hrv_ln", "awake_rest_hrv_ln"),
               ("awake_still", "upright"): ("awake_upright_hrv_ln", "awake_rest_hrv_ln")}


def series_for(kind, posture, channel):
  table = _HR_SERIES if channel == "hr" else _HRV_SERIES
  if kind == "walking" or kind == "asleep":
    posture = None
  return table.get((kind, posture), ())


# --------------------------------------------------------------------------------------------- interval rows

@dataclasses.dataclass
class IntervalRow:
  """ActivityContextIntervalRow (the fields the materializer and the context resolver read)."""
  start: int
  end: int
  activity_class: str
  confidence: float
  evidence_quality: float
  posture: str | None
  locomotion: str | None
  sleep_state: str
  wear_state: str
  intensity: float | None
  hr_samples: int
  hr_mean: float | None
  rmssd: float | None
  rr_beats: int
  rr_diff_sq_sum: float
  rr_diff_count: int

  @property
  def duration(self):
    return self.end - self.start


ROW_COLUMNS = ("startTs", "endTs", "activityClass", "confidence", "evidenceQuality", "posture", "locomotion",
               "sleepState", "wearState", "intensity", "hrSamples", "hrMean", "rmssd", "rrBeats", "rrDiffSqSumMs2",
               "rrDiffCount")
_ROW_DEFAULTS = (None, None, "unknown", 0.0, 0.0, None, None, "unknown", "unknown", None, 0, None, None, 0, 0.0, 0)


def rows_from_tuples(tuples) -> list:
  """Rows in ROW_COLUMNS order (None where a column is absent: the store's defaults apply)."""
  out = []
  for t in tuples:
    v = [d if x is None else x for x, d in zip(t, _ROW_DEFAULTS)]
    out.append(IntervalRow(int(v[0]), int(v[1]), str(v[2]), float(v[3]), float(v[4]),
                           None if t[5] is None else str(t[5]), None if t[6] is None else str(t[6]), str(v[7]),
                           str(v[8]), None if t[9] is None else float(t[9]), int(v[10]),
                           None if t[11] is None else float(t[11]), None if t[12] is None else float(t[12]),
                           int(v[13]), float(v[14]), int(v[15])))
  return out


# --------------------------------------------------------------------------------------------- materializer

MIN_CLASS_CONFIDENCE = 0.6
MIN_EVIDENCE_QUALITY = 0.5
MAX_STILL_INTENSITY = 0.40
MIN_HR_COVERAGE = 0.5
SETTLE_AFTER_TRANSITION_S = 120
SETTLE_AFTER_WALKING_S = 600
SETTLE_AFTER_VIGOROUS_S = 1800
WALKING_ON_TRANSIENT_S = 180
MIN_HRV_PAIRS = 120
_NEVER = -(1 << 40)
VIGOROUS_CLASSES = frozenset({"running", "cycling", "vigorous_activity", "brisk_walking"})
WALKING_CLASSES = frozenset({"walking"})
_NOT_STILL = object()


def posture_of(r: IntervalRow):
  """ContextMaterializer.posture(of:): class and posture channel agreeing confidently, else None."""
  if not (r.confidence >= MIN_CLASS_CONFIDENCE and r.evidence_quality >= MIN_EVIDENCE_QUALITY):
    return None
  if r.activity_class == "lying_down":
    return "supine" if r.posture in (None, "recumbent") else None
  if r.activity_class in ("sitting", "sitting_desk"):
    return "seated" if r.posture in (None, "seated_likely") else None
  if r.activity_class == "standing":
    return "upright" if r.posture in (None, "upright_stationary") else None
  return None


def _worn(r):
  if r.wear_state == "off_wrist" or not r.duration > 0:
    return False
  return float(r.hr_samples) >= MIN_HR_COVERAGE * float(r.duration)


def _still(r):
  if r.intensity is None or not r.intensity <= MAX_STILL_INTENSITY:
    return False
  return ((r.locomotion if r.locomotion is not None else "stationary") == "stationary"
          and r.activity_class not in VIGOROUS_CLASSES and r.activity_class not in WALKING_CLASSES)


def civil_day(r, tz_offset_s, asleep):
  """Epoch day of an awake interval's start, or of a sleep interval's midpoint + 6 h (the wake day), in a fixed
  UTC offset (the phone uses its calendar's time zone)."""
  ts = (r.start + r.end) // 2 + 6 * 3600 if asleep else r.start
  return (ts + int(tz_offset_s)) // 86400


class _Acc:
  __slots__ = ("hr_w", "hr_sum", "sq", "pairs", "minutes", "hr_values", "ln_values")

  def __init__(self):
    self.hr_w = 0.0; self.hr_sum = 0.0; self.sq = 0.0; self.pairs = 0; self.minutes = 0.0
    self.hr_values = []; self.ln_values = []

  def add(self, r, hr, hrv):
    if hr and r.hr_mean is not None and math.isfinite(r.hr_mean) and 30 <= r.hr_mean <= 220 and r.hr_samples > 0:
      self.hr_w += float(r.hr_samples)
      self.hr_sum += r.hr_mean * float(r.hr_samples)
      self.minutes += float(r.hr_samples) / 60
      self.hr_values.append((r.hr_mean, float(r.hr_samples)))
    if hrv:
      n = r.rr_diff_count
      s = r.rr_diff_sq_sum
      if n == 0 and r.rmssd is not None and r.rmssd > 0 and r.rr_beats >= 2:
        n = r.rr_beats - 1                 # pre-v49 row: components recovered from the stored RMSSD
        s = r.rmssd * r.rmssd * float(n)
      if n > 0 and s > 0:
        self.sq += s
        self.pairs += n
        self.ln_values.append((math.log(math.sqrt(s / float(n))), float(n)))


def weighted_median(xs):
  s = sorted(((v, w) for v, w in xs if math.isfinite(v) and w > 0), key=lambda p: p[0])
  total = 0.0
  for _, w in s:
    total += w
  if not total > 0:
    return None
  acc = 0.0
  for v, w in s:
    acc += w
    if acc >= total / 2:
      return v
  return s[-1][0] if s else None


def weighted_mad_scale(xs, l1):
  if len(xs) < 3:
    return None
  m = weighted_median(xs)
  if m is None:
    return None
  mad = weighted_median([(abs(v - m), w) for v, w in xs])
  if mad is None:
    return None
  return l1.MAD_SCALE * mad * l1._mad_small_sample_factor(len(xs))


@dataclasses.dataclass(frozen=True)
class DailyObs:
  day: int                   # epoch day (local)
  value: float | None        # native (bpm, RMSSD ms)
  status: str                # ok | low_quality | missing
  coverage: float | None
  within: float | None       # within-day scale, math space


def _gate(series: SeriesDef, value, status, coverage):
  """applyCoverageGate for the context strata."""
  if status != "ok":
    return status
  if series.coverage_required and coverage is None:
    return "low_quality"
  if (coverage if coverage is not None else 0.0) < series.coverage_need:
    return "low_quality"
  return status


def observations(rows, tz_offset_s=0, l1=None) -> dict:
  """ContextMaterializer.observations: {series key: [DailyObs by day]}."""
  l1 = l1 or load_layer1()
  acc = {}

  def add(series, day, r, hr, hrv):
    acc.setdefault(series, {}).setdefault(day, _Acc()).add(r, hr, hrv)

  bout_start = _NEVER; last_walking_end = _NEVER; last_vigorous_end = _NEVER
  prev_still = _NOT_STILL
  walking_bout_start = None
  prev_end = _NEVER
  for r in sorted(rows, key=lambda x: x.start):
    contiguous = r.start - prev_end <= 60
    is_asleep = r.sleep_state == "asleep"
    is_awake = r.sleep_state == "awake"
    is_vigorous = r.activity_class in VIGOROUS_CLASSES or r.locomotion in ("running", "brisk_walking")
    is_walking = r.activity_class in WALKING_CLASSES or r.locomotion == "walking"
    try:
      if not _worn(r):
        walking_bout_start = None; prev_still = _NOT_STILL
        continue
      if is_asleep:
        add("sleep_hr", civil_day(r, tz_offset_s, True), r, True, False)
        prev_still = _NOT_STILL; walking_bout_start = None
        continue
      if not is_awake:
        prev_still = _NOT_STILL; walking_bout_start = None
        continue
      day = civil_day(r, tz_offset_s, False)
      if is_walking and not is_vigorous and (r.intensity if r.intensity is not None else 0.0) > 0:
        if walking_bout_start is None or not contiguous:
          walking_bout_start = r.start
        if r.start - walking_bout_start >= WALKING_ON_TRANSIENT_S:
          add("walking_hr", day, r, True, False)
        prev_still = _NOT_STILL
        continue
      walking_bout_start = None
      if not _still(r):
        prev_still = _NOT_STILL
        continue
      p = posture_of(r)
      same_bout = contiguous and prev_still is not _NOT_STILL and prev_still == p
      if not same_bout:
        bout_start = r.start
      prev_still = p
      settled = (r.start - bout_start >= SETTLE_AFTER_TRANSITION_S
                 and r.start - last_walking_end >= SETTLE_AFTER_WALKING_S
                 and r.start - last_vigorous_end >= SETTLE_AFTER_VIGOROUS_S)
      if not settled:
        continue
      add("awake_rest_hr", day, r, True, False)
      add("awake_rest_hrv_ln", day, r, False, True)
      if p is not None:
        add(f"awake_{p}_hr", day, r, True, False)
        add(f"awake_{p}_hrv_ln", day, r, False, True)
    finally:
      if is_vigorous:
        last_vigorous_end = r.end
      if is_walking:
        last_walking_end = r.end
      prev_end = r.end

  out = {}
  for key, days in acc.items():
    series = SERIES[key]
    spec = l1.Series(key, series.min_val, series.max_val, series.floor, series.k_band, series.span7,
                     series.n_established, uses_log=series.uses_log)
    obs = []
    for day in sorted(days):
      a = days[day]
      if series.uses_log:
        native = math.sqrt(a.sq / float(a.pairs)) if a.pairs >= MIN_HRV_PAIRS else None
        coverage = float(a.pairs) / 60
        within = weighted_mad_scale(a.ln_values, l1)
      else:
        native = a.hr_sum / a.hr_w if a.hr_w > 0 else None
        coverage = a.minutes
        within = weighted_mad_scale(a.hr_values, l1)
      o = l1.observation(native, spec)
      obs.append(DailyObs(day, o.value, _gate(series, o.value, o.status, coverage), coverage, within))
    out[key] = obs
  return out


# --------------------------------------------------------------------------------------------- daily references

@dataclasses.dataclass(frozen=True)
class Reference:
  """One stratum's Layer 1 reference for a local day (built from days before it). Math space (ln for HRV)."""
  series: str
  day: int
  status: str                      # established | provisional | none
  n_long: int = 0
  center: float | None = None      # copyLong.center
  spread: float | None = None      # copyLong.spread (robust between-day scale)
  predictive: float | None = None  # copyLong.predictiveSpread
  n_eff: float | None = None
  within: float | None = None      # withinDayScaleLong
  established: bool = False
  stale: bool = True
  show_long: bool = False

  @property
  def scale(self):
    """WatchdogLiveReferences.lookup: sqrt(between^2 + within^2); unknown within -> the between-day spread."""
    if self.center is None:
      return None
    between = self.predictive if self.predictive is not None else self.spread
    within = self.within if self.within is not None else self.spread
    return math.sqrt(between * between + within * within)


def _reference(key, t, ev, by_day, l1, spec) -> Reference:
  long_epochs = range(t - l1.LOOKBACK_LONG, t - l1.GAP_DAYS)
  within = l1._median([o_within for e in long_epochs
                       if (o := by_day.get(e)) is not None and l1._trainable_math(o[0], spec) is not None
                       and (o_within := o[1]) is not None])
  copy = ev.copy_long
  ref = ev.ref_copy
  if copy is None:
    status = "none"
  elif ev.stale:
    status = "none"
  else:
    status = "established" if ev.established_long else "provisional"
  pred = None if copy is None else (ref.predictive_scale if ref is not None else copy.spread)
  return Reference(key, t, status, ev.n_long, None if copy is None else copy.center,
                   None if copy is None else copy.spread, pred, None if ref is None else ref.n_eff, within,
                   ev.established_long, ev.stale, ev.show_long)


def references(obs: dict, days, l1=None) -> dict:
  """{series: {day: Reference}} for every local epoch day in `days`, each from the days before it (the phone's
  `evaluate(asOf: D, observations)` with D's own value withheld). One replay per series carries the change hold, the
  CUSUM and the tail ring exactly as the phone's replay does."""
  l1 = l1 or load_layer1()
  days = sorted({int(d) for d in days})
  out = {}
  if not days:
    return out
  for key in SERIES_KEYS:
    series = SERIES[key]
    spec = l1.Series(key, series.min_val, series.max_val, series.floor, series.k_band, series.span7,
                     series.n_established, uses_log=series.uses_log)
    rows = obs.get(key, [])
    by_day = {o.day: l1.Observation(o.value, o.status) for o in rows}
    within = {o.day: (by_day[o.day], o.within) for o in rows}
    trainable = sorted(e for e, o in by_day.items() if l1._trainable_math(o, spec) is not None)
    refs = {}
    if not by_day:
      for d in days:
        refs[d] = Reference(key, d, "none")
      out[key] = refs
      continue
    carry = l1.Carry()
    start = min(by_day)
    wanted = set(days)
    for t in range(min(start, days[0]), days[-1] + 1):
      if t in wanted:
        if t <= start:
          # Nothing before t: evaluate(asOf: t) over an empty tape.
          refs[t] = Reference(key, t, "none")
        else:
          if t in by_day:
            causal_by_day = {e: o for e, o in by_day.items() if e != t}
            causal_trainable = [e for e in trainable if e != t]
          else:
            causal_by_day, causal_trainable = by_day, trainable
          ev = l1._score_one_day(t, spec, causal_by_day, causal_trainable, carry)
          refs[t] = _reference(key, t, ev, within, l1, spec)
      if t >= start:
        carry = l1._score_one_day(t, spec, by_day, trainable, carry).carry
    out[key] = refs
  return out


# --------------------------------------------------------------------------------------------- minute context

RECOVERY_AFTER_EFFORT_S = 30 * 60
RECOVERY_AFTER_WALKING_S = 10 * 60
TRANSITION_WINDOW_S = 3 * 60
HR_SCALE_FLOOR = 5.0     # WatchdogConfig.hrScale (bpm)
HRV_SCALE_FLOOR_MS = 8.0  # WatchdogConfig.hrvScale (ms)
KINDS = ("asleep", "awake_still", "walking", "active", "unknown")


@dataclasses.dataclass
class MinuteContext:
  """WatchdogMinuteContext per minute (arrays)."""
  minute: np.ndarray       # unix seconds
  kind: np.ndarray         # str
  posture: np.ndarray      # object: None | supine | seated | upright
  since_effort: np.ndarray  # float seconds, NaN = none in view
  since_walking: np.ndarray
  transition: np.ndarray   # bool


def resolve_transitions(minutes, kinds, postures, grid=60) -> MinuteContext:
  """WatchdogContextResolver.resolve, lines 195-206, over the whole timeline (the phone runs it over its 30-minute
  window): time since the end of the last effort / walking minute, and a kind change or an awake-still posture
  change within the last 3 minutes."""
  n = len(minutes)
  since_e = np.full(n, np.nan); since_w = np.full(n, np.nan); trans = np.zeros(n, bool)
  last_effort = last_walk = last_trans = None
  prev_kind = None; prev_posture = _NOT_STILL
  for i in range(n):
    m = int(minutes[i]); kind = kinds[i]; posture = postures[i] if kind == "awake_still" else None
    if kind == "active":
      last_effort = m + grid
    if kind == "walking":
      last_walk = m + grid
    if prev_kind is not None and prev_kind != kind:
      last_trans = m
    if kind == "awake_still" and prev_posture is not _NOT_STILL and prev_posture != posture:
      last_trans = m
    prev_kind = kind; prev_posture = posture
    if last_effort is not None:
      since_e[i] = m - last_effort
    if last_walk is not None:
      since_w[i] = m - last_walk
    trans[i] = last_trans is not None and m - last_trans < TRANSITION_WINDOW_S
  return MinuteContext(np.asarray(minutes, np.int64), np.asarray(kinds, dtype=object),
                       np.asarray([p if k == "awake_still" else None for p, k in zip(postures, kinds)], dtype=object),
                       since_e, since_w, trans)


def settling(mc: MinuteContext) -> np.ndarray:
  """WatchdogExpectation.settling."""
  still = mc.kind == "awake_still"
  with np.errstate(invalid="ignore"):
    eff = np.isfinite(mc.since_effort) & (mc.since_effort < RECOVERY_AFTER_EFFORT_S)
    walk = np.isfinite(mc.since_walking) & (mc.since_walking < RECOVERY_AFTER_WALKING_S)
  return mc.transition | (still & (eff | walk))


@dataclasses.dataclass
class Track:
  """Per-minute Layer 1 expectation for one channel, math space (ln RMSSD for HRV)."""
  expected: np.ndarray     # (N,) NaN = no reference
  scale: np.ndarray        # sqrt(between^2 + within^2), NaN = none
  scale_floored: np.ndarray  # with the Watchdog floors (HR 5 bpm; HRV 8 ms, as ln: asinh(8 / e^c))
  status: np.ndarray       # str: established | provisional | none
  series: np.ndarray       # object: series key or None
  days: np.ndarray         # n_long behind the reference (0 = none)


def track(channel, mc: MinuteContext, day: np.ndarray, refs: dict, allow_provisional=True) -> Track:
  """WatchdogExpectation.track: first established, non-stale series for the minute's context (posture stratum, else
  pooled awake rest); nothing while settling. With allow_provisional, a minute with no established reference uses
  the first provisional one (flagged)."""
  n = len(mc.minute)
  exp_ = np.full(n, np.nan); sc = np.full(n, np.nan); scf = np.full(n, np.nan)
  status = np.full(n, "none", dtype=object); used = np.full(n, None, dtype=object); nd = np.zeros(n)
  settle = settling(mc)
  cache = {}
  for i in range(n):
    if settle[i]:
      continue
    key = (mc.kind[i], mc.posture[i], int(day[i]))
    hit = cache.get(key)
    if hit is None:
      hit = _pick(series_for(mc.kind[i], mc.posture[i], channel), int(day[i]), refs, allow_provisional)
      cache[key] = hit
    if hit is False:
      continue
    ref = hit
    s = ref.scale
    exp_[i] = ref.center; sc[i] = s
    if channel == "hrv":
      mid = math.exp(ref.center)
      scf[i] = math.asinh(max(HRV_SCALE_FLOOR_MS, mid * math.sinh(s)) / mid)
    else:
      scf[i] = max(HR_SCALE_FLOOR, s)
    status[i] = ref.status; used[i] = ref.series; nd[i] = ref.n_long
  return Track(exp_, sc, scf, status, used, nd)


def _pick(keys, day, refs, allow_provisional):
  for want in (("established",), ("provisional",)) if allow_provisional else (("established",),):
    for k in keys:
      ref = refs.get(k, {}).get(day)
      if ref is not None and ref.status in want:
        return ref
  return False


# --------------------------------------------------------------------------------------------- timeline wiring

# Engine context (context.CONTEXTS) -> Watchdog minute kind. Recovery is awake still; the Watchdog's own settling
# rule (30 min after effort, 10 after walking) then decides whether it is drawn.
_KIND_OF_CONTEXT = {"asleep": "asleep", "still_supine": "awake_still", "still_seated": "awake_still",
                    "still_upright": "awake_still", "still_unknown": "awake_still", "recovery": "awake_still",
                    "walking": "walking", "active": "active", "off": "unknown", "unknown": "unknown"}


@dataclasses.dataclass
class Layer1:
  """Per-minute Layer 1 tracks for a timeline, plus the per-stratum references behind them."""
  available: bool
  reason: str | None
  tracks: dict             # "hr" | "hrv" -> Track
  refs: dict               # series -> {day: Reference}
  context: MinuteContext | None

  def summary(self, day=None) -> dict:
    """Per stratum as of `day` (default the timeline's last day): status, days, center / scale in physical units."""
    out = {}
    for key, by_day in self.refs.items():
      if not by_day:
        continue
      d = max(by_day) if day is None else day
      ref = by_day.get(d)
      if ref is None:
        continue
      series = SERIES[key]
      item = {"series": key, "stratum": STRATUM_NAMES[key], "channel": series.channel, "status": ref.status,
              "days": int(ref.n_long), "n_eff": ref.n_eff, "stale": bool(ref.stale),
              "unit": "ms" if series.uses_log else "bpm", "center": None, "scale": None}
      if ref.center is not None:
        if series.uses_log:
          mid = math.exp(ref.center)
          item["center"] = mid; item["scale"] = mid * math.sinh(ref.scale)
        else:
          item["center"] = ref.center; item["scale"] = ref.scale
      out[key] = item
    return out


def unavailable(n, reason) -> Layer1:
  none = Track(np.full(n, np.nan), np.full(n, np.nan), np.full(n, np.nan), np.full(n, "none", dtype=object),
               np.full(n, None, dtype=object), np.zeros(n))
  return Layer1(False, reason, {"hr": none, "hrv": none}, {}, None)


def compute(tl, ctx) -> Layer1:
  """Layer 1 tracks for every minute of `tl` from the interval rows its loader attached (`tl.meta`)."""
  n = len(tl)
  rows = tl.meta.get("context_intervals")
  if rows is None:
    return unavailable(n, tl.meta.get("layer1_unavailable") or UNAVAILABLE_SERVER)
  l1 = load_layer1()
  if l1 is None:
    return unavailable(n, "the Layer 1 statistics module (Tools/MetricInsight layer1.py) is not installed")
  from .context import CONTEXTS
  from .timeline import interval_lookup
  tz = int(tl.tz_offset_s)
  obs = observations(rows, tz, l1)
  day = np.asarray(tl.local_day, dtype=np.int64)
  refs = references(obs, np.unique(day), l1)
  kinds = [_KIND_OF_CONTEXT[CONTEXTS[int(c)]] for c in ctx.code]
  # Posture: ContextMaterializer.posture(of:) on the stored interval at the minute's midpoint (latest start wins).
  if rows:
    k = interval_lookup(tl.minutes, [r.start for r in rows], [r.end for r in rows])
    post = [posture_of(rows[j]) if j >= 0 else None for j in k]
  else:
    post = [None] * n
  mc = resolve_transitions(tl.minutes, kinds, post)
  tracks = {ch: track(ch, mc, day, refs) for ch in ("hr", "hrv")}
  return Layer1(True, None, tracks, refs, mc)


def cached(tl, ctx) -> Layer1:
  """`compute` once per timeline and context (the Layer 1 references never depend on a fit mask or cutoff: each day
  only uses days before it)."""
  hit = tl.meta.get("_layer1_cache")
  if hit is not None and hit[0] is tl.minutes and hit[1] is ctx.code:
    return hit[2]
  out = compute(tl, ctx)
  tl.meta["_layer1_cache"] = (tl.minutes, ctx.code, out)
  return out
