import json
import os
import subprocess
import sys
import unittest

import numpy as np

from personal_events import engine
from personal_events import detector as det
from personal_events.context import classify
from personal_events.evaluation import fit_models, forward, rng_for
from personal_events.evidence import Evidence
from personal_events.inject import PlantSpec, parse_spec, plant
from personal_events.policy import EpisodeState
from personal_events.report import validate
from synth import event_onsets, events_at, make_timeline, plant_hr

HERE = os.path.dirname(os.path.abspath(__file__))


class Detectability(unittest.TestCase):
  def test_expected_recall_matches_the_spec_table(self):
    want = {1: 0.09, 1.5: 0.20, 2: 0.37, 3: 0.75, 4: 0.95}
    for d, r in want.items():
      self.assertAlmostEqual(det.expected_recall(d)["1"], r, delta=0.011)
    self.assertLess(det.expected_recall(2)["0.5"], det.expected_recall(2)["1"])
    self.assertLess(det.expected_recall(2)["1"], det.expected_recall(2)["2"])
    self.assertEqual(det.expected_recall(None), {"0.5": None, "1": None, "2": None})

  def test_separation(self):
    rng = np.random.default_rng(0)
    d = det.separation(rng.normal(2, 1, 4000), rng.normal(0, 1, 4000))
    self.assertAlmostEqual(d, 2, delta=0.1)

  def test_certified_threshold_abstains_on_short_negative_time(self):
    rng = np.random.default_rng(1)
    times = 60.0 * np.arange(1440)                                   # one day < 1.61 days needed at 1/day
    th = det.certify(times, rng.normal(0, 1, 1440), budget=1.0)
    self.assertIsNone(th.enter); self.assertIn("days of negative time", th.reason)
    times = 60.0 * np.arange(5 * 1440)
    th = det.certify(times, rng.normal(0, 1, 5 * 1440), budget=1.0)
    self.assertIsNotNone(th.enter)
    self.assertLessEqual(det.poisson_upper(th.false_alerts) / th.monitored_days, 1.0)

  def test_poisson_upper_and_wilson(self):
    self.assertAlmostEqual(det.poisson_upper(0), -np.log(0.2), places=6)
    lo, hi = det.wilson(5, 10)
    self.assertTrue(lo < 0.5 < hi)


class Episodes(unittest.TestCase):
  def test_vectorised_episodes_equal_episode_state(self):
    rng = np.random.default_rng(3)
    for trial in range(30):
      n = 3000
      t = 60.0 * np.arange(n) + 1e6
      s = np.convolve(rng.normal(0, 1, n), np.ones(5) / 5, "same") * 2
      s[rng.random(n) < 0.02] = np.nan
      gap = rng.random(n) < 0.005
      t = t + 600 * np.cumsum(gap)
      enter, exit_ = 1.0 + rng.random(), 0.5
      fast = det.episodes(t, s, enter, exit_)
      ref = det.run_episode_state(t, s, enter, exit_, sigma=1.0)
      self.assertEqual([tuple(map(float, x)) for x in fast], sorted(ref), trial)


class Forward(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    tl = make_timeline(days=22, seed=11)
    cls.onsets = event_onsets(tl, 12, np.random.default_rng(11))
    cls.tl = plant_hr(tl, cls.onsets, amp=14.0)
    cls.ev = Evidence("T", events_at(cls.onsets, unc=5), owner="o")

  def test_no_future_leakage(self):
    ctx = classify(self.tl)
    fwd = forward(self.tl, ctx, self.ev, "context", "o")
    self.assertTrue(fwd["evaluated"])
    for seg in fwd["segments"]:
      if "skipped" in seg:
        continue
      self.assertLess(seg["train_last_minute"], seg["cutoff"])            # training windows end before test
      self.assertLessEqual(seg["train_last_label_available"], seg["cutoff"])
      self.assertGreaterEqual(seg["train_events"], 3)

  def test_fit_ignores_data_and_labels_after_cutoff(self):
    ctx = classify(self.tl)
    cutoff = float(self.onsets[6] - 3600)
    a = fit_models(self.tl, ctx, self.ev, "context", cutoff, rng_for("o", "T", cutoff))
    t2 = self.tl.copy()
    i = int(t2.index(cutoff))
    t2.cols["hr"][i:] += 30                                             # future data changed
    ev2 = Evidence("T", self.ev.events[:7] + events_at([self.onsets[-1] + 7200], prefix="x"), owner="o")
    b = fit_models(t2, classify(t2), ev2, "context", cutoff, rng_for("o", "T", cutoff))
    for m in det.METHODS:
      self.assertEqual(vars(a.thresholds[m]), vars(b.thresholds[m]), m)
    np.testing.assert_array_equal(a.normalizer.params["hr"]["center"], b.normalizer.params["hr"]["center"])
    np.testing.assert_array_equal(a.scores["logistic"][:i], b.scores["logistic"][:i])

  def test_report_schema_and_determinism(self):
    r1, d1, f1 = engine.run(self.tl, self.ev, generated_at=123)
    r2, d2, f2 = engine.run(self.tl, self.ev, generated_at=123)
    self.assertEqual(validate(r1), [])
    self.assertEqual(json.dumps(r1, sort_keys=True), json.dumps(r2, sort_keys=True))
    self.assertEqual(json.dumps(f1, sort_keys=True, default=str), json.dumps(f2, sort_keys=True, default=str))
    json.dumps(r1, allow_nan=False)
    self.assertIs(r1["alerts_enabled"], False)
    self.assertTrue(r1["retrospective"]["evaluated"])
    self.assertGreater(r1["detectability"]["d"], 1.5)

  def test_validator_rejects_bad_reports(self):
    r, _, _ = engine.run(self.tl, self.ev, generated_at=1, forward_eval=False)
    self.assertEqual(validate(r), [])
    for mutate in (lambda x: x.pop("status"), lambda x: x.update(status="great"),
                   lambda x: x["signatures"][0].update(extra=1), lambda x: x.update(alerts_enabled=True),
                   lambda x: x["detectability"].update(assessment="sure"),
                   lambda x: x["signatures"][0]["profile"]["channels"]["hr"]["mean"].pop()):
      bad = json.loads(json.dumps(r)); mutate(bad)
      self.assertNotEqual(validate(bad), [])

  def test_insufficient_and_empty_inputs_still_produce_valid_reports(self):
    r, _, _ = engine.run(self.tl, Evidence("T", self.ev.events[:2], owner="o"), generated_at=1)
    self.assertEqual((r["status"], validate(r)), ("insufficient_events", []))
    self.assertEqual(r["detectability"]["assessment"], "insufficient_data")
    r, _, _ = engine.run(None, Evidence("T", [], owner="o"), generated_at=1)
    self.assertEqual((r["status"], validate(r)), ("insufficient_events", []))

  def test_normalization_modes_run(self):
    for mode in ("raw", "context+response"):
      r, _, _ = engine.run(self.tl, self.ev, normalization=mode, generated_at=1, forward_eval=False)
      self.assertEqual(validate(r), [])
      self.assertEqual(r["engine"]["normalization"], mode)


class Inject(unittest.TestCase):
  def test_plant_adds_effect_and_jitters_within_uncertainty(self):
    tl = make_timeline(days=12, seed=2)
    spec = parse_spec("n=5,hr=10,hrv=-0.2,dur=10,unc=5,seed=4")
    self.assertEqual(spec.effects, {"hr": 10.0, "hrv": -0.2})
    planted, events, truth = plant(tl, spec)
    self.assertEqual(len(events), 5)
    for e, t in zip(events, truth):
      self.assertLessEqual(abs(t["logged_onset"] - t["true_onset"]), 5 * 60)
      i = int(tl.index(t["true_onset"]))
      self.assertAlmostEqual(planted["hr"][i + 4] - tl["hr"][i + 4], 10.0)
      self.assertEqual(np.isnan(planted["ln_rmssd"]).sum(), np.isnan(tl["ln_rmssd"]).sum())
    self.assertEqual(len({int(tl.local_day[int(tl.index(t["true_onset"]))]) for t in truth}), 5)
    self.assertFalse(np.shares_memory(planted["hr"], tl["hr"]))


class Worker(unittest.TestCase):
  def test_infer_lane_never_publishes(self):
    env = dict(os.environ, NARA_EVENT_DETECTION_ENABLED="1", PYTHONPATH=os.path.dirname(HERE))
    env.pop("NARA_EVENT_DETECTION_PUBLISH", None)
    env.pop("NARA_EVENT_DATABASE_URL", None)
    out = subprocess.run([sys.executable, "-m", "personal_events.worker", "--lane", "infer"], env=env,
                         capture_output=True, text=True, timeout=60)
    self.assertEqual(out.returncode, 0); self.assertIn("disabled", out.stderr)
    env["NARA_EVENT_DETECTION_PUBLISH"] = "1"
    out = subprocess.run([sys.executable, "-m", "personal_events.worker", "--lane", "infer"], env=env,
                         capture_output=True, text=True, timeout=60)
    self.assertEqual(out.returncode, 0); self.assertIn("nothing to run", out.stderr)


if __name__ == "__main__":
  unittest.main()
