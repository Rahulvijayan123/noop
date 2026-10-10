"""Layer 1 context-strata baselines (layer1_context.py) and the `layer1` / `layer1+tod` normalisations.

tests/data/layer1_context_expected.json is recorded from the app's own code (ContextMaterializer.observations,
LongitudinalBaseline.evaluate, WatchdogLiveReferences.lookup, WatchdogExpectation.track) by
Packages/StrandAnalytics/Tests/StrandAnalyticsTests/LayerOneContextMirrorTests for the invented tapes in
tests/data/layer1_context_cases.json (scripts/make_layer1_context_cases.py). That Swift test fails when the phone's
code changes; this one fails until the port follows. No personal data anywhere.
"""
import json
import math
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

import numpy as np

from personal_events import layer1_context as L
from personal_events.baseline import Normalizer, SOURCES, fit_mask
from personal_events.context import classify
from personal_events.report import validate_baselines
from personal_events.timeline import load_whoop_sqlite
from synth import T0, make_timeline

DATA = Path(__file__).parent / "data"
REL = 1e-9


def close(a, b):
  if a is None or b is None:
    return a is None and b is None
  return abs(a - b) <= REL * max(1.0, abs(a), abs(b))


class SwiftMirror(unittest.TestCase):
  """The port reproduces the app's results for every case, within 1e-9 relative."""

  @classmethod
  def setUpClass(cls):
    cls.l1 = L.load_layer1()
    cls.cases = json.loads((DATA / "layer1_context_cases.json").read_text())["cases"]
    cls.expected = json.loads((DATA / "layer1_context_expected.json").read_text())["expected"]

  def test_layer1_statistics_are_shared_not_copied(self):
    self.assertIsNotNone(self.l1)
    self.assertTrue(hasattr(self.l1, "_window_copy") and hasattr(self.l1, "_score_one_day"))

  def test_cases_match_the_recording(self):
    self.assertEqual(set(self.expected), {c["name"] for c in self.cases})
    checked = 0
    for case in self.cases:
      with self.subTest(case=case["name"]):
        checked += self._check(case, self.expected[case["name"]])
    self.assertGreater(checked, 800)

  def _check(self, case, exp):
    n = 0
    rows = L.rows_from_tuples(case["rows"])
    obs = L.observations(rows, case["tz_offset_s"], self.l1)
    # Daily stratum values.
    self.assertEqual(set(obs), set(exp["observations"]))
    for key, rec in exp["observations"].items():
      got = obs[key]
      self.assertEqual(len(got), len(rec), key)
      for o, (day, value, status, coverage, within) in zip(got, rec):
        self.assertEqual(self.l1.date.fromordinal(o.day + self.l1._EPOCH).isoformat(), day)
        self.assertEqual(o.status, status, f"{key} {day}")
        for a, b in ((o.value, value), (o.coverage, coverage), (o.within, within)):
          self.assertTrue(close(a, b), f"{key} {day}: {a} vs {b}")
        n += 1
    refs = L.references(obs, case["as_of"], self.l1)
    for day in case["as_of"]:
      # Per-stratum evaluation as of the day, from the days before it.
      for key, rec in exp["evaluations"][str(day)].items():
        r = refs[key][day]
        self.assertEqual(r.status, rec["status"], f"{key} as of {day}")
        self.assertEqual(r.n_long, rec["n_long"], f"{key} as of {day}")
        self.assertEqual(r.show_long, rec["show_long"]); self.assertEqual(r.stale, rec["stale"])
        self.assertEqual(r.established, rec["established_long"])
        self.assertEqual({"none": "none", "learning": "provisional", "established": "established",
                          "mature": "established"}[rec["maturity"]],
                         "none" if r.n_long < 4 else ("established" if r.established else "provisional"))
        for a, b in ((r.center, rec["center"]), (r.spread, rec["spread"]), (r.predictive, rec["predictive_spread"]),
                     (r.n_eff, rec["n_eff"]), (r.within, rec["within_day_scale_long"])):
          self.assertTrue(close(a, b), f"{key} as of {day}: {a} vs {b}")
        n += 1
      # The reference the Watchdog draws for each context (established only).
      for k, rec in exp["references"][str(day)].items():
        channel, kind, posture = k.split("|")
        hit = L._pick(L.series_for(kind, None if posture == "-" else posture, channel.lower()), day, refs, False)
        if rec is None:
          self.assertIs(hit, False, f"{k} as of {day}")
        else:
          self.assertIsNot(hit, False, f"{k} as of {day}")
          self.assertEqual(hit.series, rec["series"])
          self.assertTrue(close(hit.center, rec["center"]) and close(hit.scale, rec["scale"]), k)
          self.assertEqual(hit.within is not None, rec["within_known"])
        n += 1
      # The per-minute expectation (WatchdogExpectation.track): HR in bpm, HRV drawn in ms from the ln reference.
      minutes = [m for m in case["minutes"] if m[6] == day]
      mc = L.MinuteContext(np.array([m[0] for m in minutes]), np.array([m[1] for m in minutes], dtype=object),
                           np.array([m[2] for m in minutes], dtype=object),
                           np.array([np.nan if m[3] is None else m[3] for m in minutes], dtype=float),
                           np.array([np.nan if m[4] is None else m[4] for m in minutes], dtype=float),
                           np.array([m[5] for m in minutes], dtype=bool),
                           np.array([m[7] for m in minutes], dtype=bool))
      days = np.full(len(minutes), day)
      for channel, rec in exp["track"][str(day)].items():
        t = L.track(channel.lower(), mc, days, refs, allow_provisional=False)
        for i, (center, scale, series) in enumerate(rec):
          if center is None:
            self.assertTrue(np.isnan(t.expected[i]), f"{channel} minute {i} as of {day}")
            continue
          c, s = t.expected[i], t.scale[i]
          if channel == "HRV":
            c, s = math.exp(c), math.exp(c) * math.sinh(s)
          self.assertTrue(close(c, center) and close(s, scale), f"{channel} {i}: {c},{s} vs {center},{scale}")
          self.assertEqual(t.series[i], series)
          n += 1
    return n


class MinuteContextRules(unittest.TestCase):
  def test_settling_after_effort_walking_and_transitions(self):
    m = T0 + 60 * np.arange(60)
    kinds = (["walking"] * 3 + ["awake_still"] * 15 + ["active"] * 3 + ["awake_still"] * 20 + ["active"]
             + ["awake_still"] * 18)
    postures = [None] * 3 + ["seated"] * 8 + ["upright"] * 7 + [None] * 3 + ["seated"] * 39
    mc = L.resolve_transitions(m, kinds, postures)
    settle = L.settling(mc)
    # Walking ends at minute 3: still minutes settle while < 10 min since (minutes 3..12), and the kind change at
    # minute 3 and the posture change at 11 are transitions for 3 minutes.
    self.assertEqual(mc.since_walking[3], 0.0)
    self.assertTrue(settle[3:13].all())
    self.assertTrue(mc.transition[11] and mc.transition[13] and not mc.transition[14])
    self.assertTrue(settle[13])                  # past the walking settle, still inside the posture transition
    self.assertFalse(settle[14])
    # A bout (3 active minutes at 18-20): 10 minutes of settle after its end, then steady state.
    self.assertEqual(mc.since_effort[21], 0.0)
    self.assertTrue(settle[21:31].all())
    self.assertFalse(settle[31:41].any())
    # An isolated active minute at 41: 2 minutes (both also a transition), then steady state from minute 45.
    self.assertTrue(mc.settling[42] and mc.settling[43] and not mc.settling[44])
    self.assertFalse(settle[45:].any())
    self.assertTrue(np.isnan(mc.since_effort[0]))
    self.assertEqual(list(mc.posture[:3]), [None] * 3)

  def test_exercise_contexts_use_their_own_series_and_never_settle(self):
    self.assertEqual(L.series_for("exercise_session", None, "hr"), ("exercise_session_hr",))
    self.assertEqual(L.series_for("recovery", "seated", "hr"), ("exercise_recovery_hr",))
    self.assertEqual(L.series_for("recovery", None, "hrv"), ())
    m = T0 + 60 * np.arange(30)
    kinds = ["exercise_session"] * 20 + ["recovery"] * 10
    mc = L.resolve_transitions(m, kinds, [None] * 30)
    self.assertFalse(L.settling(mc)[23:].any())   # recovery right after the session: no settle, past the transition

  def test_kind_and_posture_select_the_series(self):
    self.assertEqual(L.series_for("awake_still", "seated", "hr"), ("awake_seated_hr", "awake_rest_hr"))
    self.assertEqual(L.series_for("awake_still", None, "hrv"), ("awake_rest_hrv_ln",))
    self.assertEqual(L.series_for("walking", None, "hrv"), ())
    self.assertEqual(L.series_for("asleep", None, "hrv"), ())
    self.assertEqual(L.series_for("active", None, "hr"), ())


def interval_rows(tl, *, seated_hr=72.0, sleep_hr=56.0, seed=1):
  """Synthetic interval rows behind a synthetic timeline: 10-minute rows, asleep at night, seated while still."""
  rng = np.random.default_rng(seed)
  rows = []
  for start in range(int(tl.minutes[0]), int(tl.minutes[-1]) + 60, 600):
    i = (start - int(tl.minutes[0])) // 60
    asleep = tl["asleep"][i] == 1
    hr = (sleep_hr if asleep else seated_hr) + rng.normal(0, 1.5)
    rm = float(np.exp(rng.normal(np.log(45), 0.1)))
    n = int(hr * 10) - 3
    rows.append((start, start + 600, "sleeping" if asleep else "sitting", 0.9, 0.8, None if asleep else "seated_likely",
                 "stationary", "asleep" if asleep else "awake", "on_wrist", 0.02 if asleep else 0.1, 590, round(hr, 2),
                 round(rm, 2), n + 1, rm * rm * n, n))
  return L.rows_from_tuples(rows)


class Layer1Normalisation(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls.tl = make_timeline(days=40, seed=4)
    cls.tl.meta["context_intervals"] = interval_rows(cls.tl)
    cls.ctx = classify(cls.tl)
    cls.mask = fit_mask(cls.tl, cls.ctx)

  def test_sources_and_fallback(self):
    norm = Normalizer("layer1").fit(self.tl, self.ctx, self.mask)
    dev = norm.transform(self.tl, self.ctx)
    for ch in ("hr", "hrv", "temp", "motion"):
      self.assertTrue(set(np.unique(dev.source[ch].astype(str))) <= set(SOURCES))
    day = self.tl.local_day - self.tl.local_day[0]
    src = dev.source["hr"].astype(str)
    still = np.isin(self.ctx.code, [1, 2, 3, 4])
    # No reference in the first 11 days (T-60 ... T-8 has < 4 days): the engine's context baseline is used.
    self.assertTrue((src[day < 11] != "layer1_established").all())
    self.assertTrue((src[(day < 11) & still & np.isfinite(dev.z["hr"])] == "engine_context").all())
    # From 22 days the seated and sleep references are established and drawn.
    late = (day >= 23) & np.isfinite(self.tl["hr"])
    self.assertGreater(np.mean(src[late & (self.ctx.code == 0)] == "layer1_established"), 0.95)
    self.assertIn("layer1_provisional", set(src[(day >= 12) & (day < 21)]))
    # z is (x - Layer 1 expected) / Layer 1 scale (floored at 5 bpm) where Layer 1 is used.
    t = L.cached(self.tl, self.ctx).tracks["hr"]
    use = src == "layer1_established"
    np.testing.assert_allclose(dev.expected["hr"][use], t.expected[use])
    np.testing.assert_allclose(dev.z["hr"][use], (self.tl["hr"][use] - t.expected[use]) / t.scale_floored[use])
    self.assertTrue((t.scale_floored[use] >= 5.0).all())
    # Walking minutes have no steady-walking stratum here: engine baseline.
    walking = (self.ctx.code == 5) & np.isfinite(dev.z["hr"])
    self.assertTrue((src[walking] == "engine_context").all())
    # Other channels never use Layer 1; support is the reference's days where Layer 1 is used.
    self.assertFalse(np.isin(dev.source["temp"].astype(str), ["layer1_established", "layer1_provisional"]).any())
    self.assertTrue((dev.support["hr"][use] >= 14).all())

  def test_tod_offsets_ignore_excluded_minutes(self):
    base = Normalizer("layer1+tod").fit(self.tl, self.ctx, self.mask)
    tl2 = self.tl.copy()
    day30 = int(np.flatnonzero(self.tl.local_day - self.tl.local_day[0] == 30)[0])
    tl2.cols["hr"] = tl2["hr"].copy(); tl2.cols["hr"][day30 + 600:day30 + 660] += 40
    ctx2 = classify(tl2)
    excl = [(float(self.tl.minutes[day30 + 600]), float(self.tl.minutes[day30 + 660]))]
    shifted = Normalizer("layer1+tod").fit(tl2, ctx2, fit_mask(tl2, ctx2, excl))
    clean = Normalizer("layer1+tod").fit(self.tl, self.ctx, fit_mask(self.tl, self.ctx, excl))
    self.assertEqual(shifted.info["tod_offsets"], clean.info["tod_offsets"])
    self.assertIn("awake_seated_hr", base.info["tod_offsets"]["hr"])
    dev = base.transform(self.tl, self.ctx)
    t = L.cached(self.tl, self.ctx).tracks["hr"]
    use = (t.series == "awake_seated_hr") & np.isfinite(dev.expected["hr"])
    off = base.tod["hr"]["awake_seated_hr"][self.ctx.band[use]]
    np.testing.assert_allclose(dev.expected["hr"][use], t.expected[use] + off)

  def test_baselines_summary_validates(self):
    norm = Normalizer("layer1").fit(self.tl, self.ctx, self.mask)
    b = norm.baselines(self.tl, self.ctx)
    self.assertEqual(validate_baselines(json.loads(json.dumps(b, default=float))), [])
    seated = [c for c in b["channels"]["hr"]["contexts"] if c.get("series") == "awake_seated_hr"][0]
    self.assertEqual(seated["status"], "established")
    self.assertGreaterEqual(seated["days"], 14)
    self.assertAlmostEqual(seated["center"], 72.0, delta=1.5)
    self.assertEqual(validate_baselines({"mode": "layer1", "channels": {"hr": {"sources": {"bogus": 1}}}}),
                     ["baselines.hr", "baselines.hr.sources"])

  def test_no_intervals_means_no_layer1(self):
    tl = make_timeline(days=6, seed=2)
    tl.meta.update(context_intervals=None, layer1_unavailable=L.UNAVAILABLE_SERVER)
    ctx = classify(tl)
    norm = Normalizer("layer1").fit(tl, ctx, fit_mask(tl, ctx))
    dev = norm.transform(tl, ctx)
    ref = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx)).transform(tl, ctx)
    np.testing.assert_array_equal(dev.z["hr"], ref.z["hr"])
    self.assertFalse(np.isin(dev.source["hr"].astype(str), ["layer1_established", "layer1_provisional"]).any())
    self.assertEqual(norm.info["layer1"], {"available": False, "reason": L.UNAVAILABLE_SERVER})


class SqliteIntervals(unittest.TestCase):
  def test_loader_reads_interval_history_read_only(self):
    with tempfile.TemporaryDirectory() as d:
      path = os.path.join(d, "whoop.sqlite")
      c = sqlite3.connect(path)
      cols = ", ".join(f'"{x}"' for x in ("deviceId",) + L.ROW_COLUMNS)
      c.executescript(f"""
        create table hrSample(deviceId text, ts integer, bpm integer);
        create table activityContextInterval({cols}, "respRateBpm" double);""")
      for t in range(T0, T0 + 600):
        c.execute("insert into hrSample values('a',?,70)", (t,))
      old = T0 - 30 * 86400
      for dev, start in (("a", old), ("a", T0), ("b", T0)):
        c.execute(f"insert into activityContextInterval values(?,?,?,'sitting',0.9,0.8,'seated_likely','stationary',"
                  f"'awake','on_wrist',0.1,590,70.5,40.0,700,1120000.0,700,null,null,null)", (dev, start, start + 600))
      c.commit(); c.close()
      mtime = os.path.getmtime(path)
      tl = load_whoop_sqlite(path, "a", T0, T0 + 600, 0)
      self.assertEqual(os.path.getmtime(path), mtime)
      rows = tl.meta["context_intervals"]
      self.assertEqual([r.start for r in rows], [old, T0])      # history before the timeline, one device only
      self.assertEqual((rows[0].hr_samples, rows[0].rr_diff_count, rows[0].posture), (590, 700, "seated_likely"))
      self.assertIsNone(tl.meta["layer1_unavailable"])


if __name__ == "__main__":
  unittest.main()
