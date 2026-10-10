"""Write tests/data/layer1_context_cases.json: invented activity-context interval tapes (never anyone's data) that
exercise every path of the Layer 1 context strata - sleep HR, awake rest, lying / seated / standing, steady walking,
the HRV strata; the settling rules (bout start, 10 min after walking, 30 min after vigorous, the walking
on-transient); missing HRV, pre-v49 rows, low class confidence, posture disagreement, off-wrist and thin HR, unknown
intensity; coverage gates; none / provisional / established references and staleness - plus minute contexts for the
per-minute expectation.

The expected results come from the app, never from the port. After changing the cases (or Layer 1):
    python scripts/make_layer1_context_cases.py
    cd ../../Packages/StrandAnalytics && LAYER1_CONTEXT_RECORD=1 swift test --filter LayerOneContextMirrorTests
records tests/data/layer1_context_expected.json with ContextMaterializer.observations, LongitudinalBaseline.evaluate,
WatchdogLiveReferences.lookup and WatchdogExpectation.track; then StrandAnalyticsTests/LayerOneContextMirrorTests and
tests/test_layer1_context.py both check against it.
"""
from __future__ import annotations

import json
import math
import random
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "tests" / "data" / "layer1_context_cases.json"
DAY0 = 20600          # epoch day of the first invented day (2026-05-26)
# Row: start, end, activityClass, confidence, evidenceQuality, posture, locomotion, sleepState, wearState,
#      intensity, hrSamples, hrMean, rmssd, rrBeats, rrDiffSqSumMs2, rrDiffCount
FIELDS = ("startTs", "endTs", "activityClass", "confidence", "evidenceQuality", "posture", "locomotion", "sleepState",
          "wearState", "intensity", "hrSamples", "hrMean", "rmssd", "rrBeats", "rrDiffSqSumMs2", "rrDiffCount")


class Tape:
  def __init__(self, tz, seed):
    self.tz = tz; self.rng = random.Random(seed); self.rows = []

  def t(self, day, hh, mm=0, ss=0):
    """Unix seconds of local day `day` (epoch day) at hh:mm:ss."""
    return day * 86400 + hh * 3600 + mm * 60 + ss - self.tz

  def run(self, start, minutes, step_s, cls, *, conf=0.85, evq=0.75, posture=None, loco="stationary",
          sleep="awake", wear="on_wrist", intensity=0.1, hr=(65, 2.5), rmssd=(45, 0.12), hrv="v49", hr_cover=0.97,
          gap_every=0):
    """Contiguous intervals of `step_s` seconds from `start` for `minutes` minutes. hrv: v49 (components), pre (only
    rmssd + rrBeats), none (no beats)."""
    rng = self.rng
    t = start; end = start + minutes * 60; k = 0
    while t < end:
      e = min(end, t + step_s)
      dur = e - t
      mean = round(rng.gauss(*hr), 1)
      n_hr = int(round(dur * hr_cover))
      rm = math.exp(rng.gauss(math.log(rmssd[0]), rmssd[1]))
      beats = int(dur * mean / 60)
      if hrv == "v49" and beats > 3:
        n = beats - 1 - rng.randint(0, 3)
        row_rm = round(rm, 2); sq = round(rm * rm * n); count = n
      elif hrv == "pre" and beats > 3:
        row_rm = round(rm, 2); sq = 0.0; count = 0
      else:
        row_rm = None; sq = 0.0; count = 0; beats = 0
      self.rows.append([t, e, cls, conf, evq, posture, loco, sleep, wear,
                        None if intensity is None else round(intensity * rng.uniform(0.8, 1.2), 2),
                        n_hr, mean if n_hr else None, row_rm, beats, sq, count])
      k += 1
      t = e + (90 if gap_every and k % gap_every == 0 else 0)   # a > 60 s gap ends a bout
    return end

  def day(self, d, profile, *, sleep_mu=54, rest_mu=66, short_seated=False, hrv="v49", skip=()):
    """One invented day: the night ending on d, then a day of activities."""
    rng = self.rng
    # Night: 23:00 (d-1) to 06:50 in 10-minute intervals, one off-wrist break and one unknown-state stretch.
    if "sleep" not in skip:
      t = self.run(self.t(d - 1, 23), 200, 1200, "sleeping", sleep="asleep", intensity=0.02, hr=(sleep_mu, 1.5),
                   rmssd=(60, 0.1), hrv=hrv)
      t = self.run(t, 10, 300, "unknown", sleep="unknown", intensity=0.05, hr=(sleep_mu + 4, 2))
      self.run(t, 260, 1200, "sleeping", sleep="asleep", intensity=0.02, hr=(sleep_mu - 1, 1.5), rmssd=(62, 0.1),
               hrv=hrv)
    # Morning: fidgeting (moving), then a seated desk bout in 5-minute intervals.
    t = self.run(self.t(d, 7), 20, 300, "fidgeting", intensity=0.6, loco="stationary", hr=(75, 3))
    if "seated" not in skip:
      t = self.run(t, 8 if short_seated else 80, 600, "sitting_desk", posture="seated_likely", hr=(rest_mu, 2.5),
                   hrv=hrv, gap_every=7)
    # Walk: 2-minute intervals (the first 180 s are the on-transient), then seated again (10-minute settling).
    if "walk" not in skip:
      t = self.run(max(t, self.t(d, 9)), 24, 120, "walking", loco="walking", intensity=0.9, hr=(96, 3), hrv="none")
      t = self.run(t, 40, 300, "sitting", posture=None, hr=(rest_mu + 2, 2.5), hrv=hrv)
    # Standing, then lying (each its own bout).
    if "upright" not in skip:
      t = self.run(max(t, self.t(d, 10)), 30, 600, "standing", posture="upright_stationary", conf=0.7, evq=0.6,
                   hr=(rest_mu + 9, 3), rmssd=(38, 0.12), hrv=hrv)
    if "supine" not in skip:
      t = self.run(t, 30, 600, "lying_down", posture="recumbent", hr=(rest_mu - 6, 2), rmssd=(58, 0.12), hrv=hrv)
    # A run (vigorous), then seated: excluded for 30 minutes.
    if profile.get("run", True):
      t = self.run(max(t, self.t(d, 12)), 20, 300, "running", loco="running", intensity=1.6, hr=(150, 6), hrv="none")
      t = self.run(t, 60, 600, "sitting", posture="seated_likely", hr=(rest_mu + 4, 3), hrv=hrv)
    # Low class confidence (pooled rest only), a stationary class without posture, a posture that disagrees.
    t = self.run(max(t, self.t(d, 14)), 30, 300, "sitting", posture="seated_likely", conf=0.45, hr=(rest_mu + 1, 2.5),
                 hrv=hrv)
    t = self.run(t, 30, 600, "stationary", posture="seated_likely", hr=(rest_mu, 2.5), hrv=hrv)
    t = self.run(t, 20, 300, "sitting", posture="upright_stationary", hr=(rest_mu + 1, 2.5), hrv=hrv)
    # Off wrist, thin HR coverage, unknown intensity (never rest), brisk walking (vigorous by class).
    t = self.run(max(t, self.t(d, 16)), 15, 300, "off_wrist", wear="off_wrist", intensity=0.0, hr=(0, 0), hr_cover=0,
                 hrv="none")
    t = self.run(t, 15, 300, "sitting", posture="seated_likely", hr=(rest_mu, 2), hr_cover=0.3, hrv=hrv)
    t = self.run(t, 15, 300, "sitting", posture="seated_likely", intensity=None, hr=(rest_mu, 2), hrv=hrv)
    if profile.get("brisk"):
      t = self.run(max(t, self.t(d, 17)), 10, 300, "brisk_walking", loco="brisk_walking", intensity=1.2, hr=(118, 4),
                   hrv="none")
    # Evening: pre-v49 rows (RMSSD only) and rows without beats, seated.
    t = self.run(max(t, self.t(d, 19)), 40, 600, "sitting", posture="seated_likely", hr=(rest_mu - 1, 2.5), hrv="pre")
    t = self.run(t, 25, 300, "sitting", posture="seated_likely", hr=(rest_mu - 1, 2.5), hrv="none")
    # An implausible interval mean (ignored by the day mean) and a long steady walk.
    t = self.run(max(t, self.t(d, 20)), 5, 300, "sitting", posture="seated_likely", hr=(25, 0.1), hrv="none")
    if profile.get("long_walk"):
      self.run(max(t, self.t(d, 21)), 30, 180, "walking", loco="walking", intensity=0.8, hr=(profile["long_walk"], 3),
               hrv="none")


def thin_day(tape, d, *, rest_hr=64, walk_hr=98):
  """A day under every coverage gate (sleep < 120 min, posture < 15 min, awake rest < 30 min, steady walking
  < 10 min), or with out-of-range day values (rest_hr < 35, walk_hr < 50)."""
  t = tape.run(tape.t(d - 1, 23, 30), 100, 600, "sleeping", sleep="asleep", intensity=0.02, hr=(55, 1.5))
  t = tape.run(max(t, tape.t(d, 8)), 12, 240, "sitting", posture="seated_likely", hr=(rest_hr, 1.5))
  t = tape.run(max(t, tape.t(d, 9)), 9, 120, "walking", loco="walking", intensity=0.9, hr=(walk_hr, 2), hrv="none")
  # One-minute lying rows: the first 120 s of the bout settle; the two rows left carry just under 120 beat pairs.
  t = tape.run(max(t, tape.t(d, 10)), 4, 60, "lying_down", posture="recumbent", hr=(rest_hr - 4, 1.5))
  if walk_hr < 50:
    tape.run(max(t, tape.t(d, 11)), 30, 180, "walking", loco="walking", intensity=0.8, hr=(walk_hr, 2), hrv="none")


def minutes_for(tape, d):
  """Minute contexts on day d: every (kind, posture), the settling rules and a transition."""
  base = tape.t(d, 12)
  out = []
  specs = [("asleep", None, None, None, False), ("awake_still", None, None, None, False),
           ("awake_still", "supine", None, None, False), ("awake_still", "seated", None, None, False),
           ("awake_still", "upright", None, None, False), ("walking", None, None, None, False),
           ("active", None, None, None, False), ("unknown", None, None, None, False),
           ("awake_still", "seated", 20 * 60, None, False), ("awake_still", "seated", 31 * 60, None, False),
           ("awake_still", "upright", None, 5 * 60, False), ("awake_still", "supine", None, 11 * 60, False),
           ("asleep", None, None, None, True), ("walking", None, None, 0, True)]
  for i, (kind, posture, eff, walk, trans) in enumerate(specs):
    out.append([base + 60 * i, kind, posture, eff, walk, trans, d])
  return out


def case_full():
  tape = Tape(-25200, 1)
  for i in list(range(24)) + list(range(40, 44)):    # 16 days without data: stale, then fresh again
    d = DAY0 + i
    if i in (8, 19):
      thin_day(tape, d)
      continue
    if i == 21:
      thin_day(tape, d, rest_hr=33, walk_hr=46)
      continue
    skip = ()
    if i % 9 == 4:
      skip = ("upright",)
    if i % 11 == 6:
      skip = ("supine", "walk")
    tape.day(d, {"run": i % 3 != 0, "brisk": i % 5 == 0, "long_walk": 100 + (i % 4) if i % 2 else 0},
             sleep_mu=54 + 0.04 * i, rest_mu=66 + (i % 6) * 0.3, short_seated=(i % 13 == 7),
             hrv="pre" if i < 3 else "v49", skip=skip)
  as_of = [DAY0, DAY0 + 9, DAY0 + 13, DAY0 + 16, DAY0 + 22, DAY0 + 30, DAY0 + 38, DAY0 + 44]
  return {"name": "full_with_a_gap", "tz_offset_s": -25200, "rows": tape.rows, "as_of": as_of,
          "minutes": [m for d in as_of for m in minutes_for(tape, d)]}


def case_short():
  tape = Tape(0, 3)
  for i in range(7):
    if i == 4:
      thin_day(tape, DAY0 + i, walk_hr=44)
      continue
    tape.day(DAY0 + i, {"run": i % 2 == 0, "brisk": True, "long_walk": 45 if i == 3 else 99},
             hrv=("pre", "none", "v49")[i % 3], short_seated=i in (2, 5), skip=("upright",) if i == 1 else ())
  as_of = [DAY0 + 3, DAY0 + 7, DAY0 + 12, DAY0 + 15, DAY0 + 23]
  return {"name": "short_edge_rows", "tz_offset_s": 0, "rows": tape.rows, "as_of": as_of,
          "minutes": [m for d in as_of for m in minutes_for(tape, d)]}


def case_held():
  """Five days, then nothing in the 60-day window: the last copy is held (Swift's v1 carry hold), fresh while new
  days keep arriving outside the window."""
  tape = Tape(-18000, 4)
  for i in list(range(5)) + list(range(70, 74)):
    tape.day(DAY0 + i, {"run": i % 2 == 0, "long_walk": 102}, rest_mu=62, sleep_mu=52)
  as_of = [DAY0 + 12, DAY0 + 74, DAY0 + 90]
  return {"name": "held_copy", "tz_offset_s": -18000, "rows": tape.rows, "as_of": as_of,
          "minutes": [m for d in as_of for m in minutes_for(tape, d)]}


def main():
  cases = [case_full(), case_short(), case_held()]
  doc = {"about": "Invented activity-context interval tapes for the Layer 1 context-strata port. Written by "
                  "Tools/PersonalEventDetection/scripts/make_layer1_context_cases.py; the expected results are "
                  "layer1_context_expected.json, recorded from the app.",
         "fields": list(FIELDS), "minute_fields": ["minute", "kind", "posture", "since_effort_s", "since_walking_s",
                                                   "recent_transition", "as_of_epoch_day"],
         "cases": cases}
  OUT.parent.mkdir(parents=True, exist_ok=True)
  OUT.write_text(json.dumps(doc, separators=(",", ":")) + "\n")
  print(f"{len(cases)} cases, {sum(len(c['rows']) for c in cases)} rows -> {OUT}")


if __name__ == "__main__":
  main()
