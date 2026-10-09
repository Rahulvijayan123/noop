"""sig-2 behaviour: audit fixes (A1-A8) and validation findings (V1-V9). Synthetic data only."""
import json
import os
import sqlite3
import tempfile
import unittest
from unittest import mock

import numpy as np

from personal_events import cli, engine
from personal_events import detector as det
from personal_events.context import classify
from personal_events.evaluation import (champion_vs_challenger, detectability, fit_models, forward, preferred_spans,
                                        promotion, rng_for)
from personal_events.evidence import Evidence
from personal_events.report import validate
from personal_events.timeline import load_whoop_sqlite, minute_grid, rr_pairs_per_minute
from synth import T0, event_onsets, events_at, make_timeline, make_walking_timeline, plant_hr


def uniform_walk_onsets(tl, walking, k, rng, pre=15, u=0, gap=240):
  """Null onsets: uniformly random minutes whose whole pre-window [i - u - 15, i - u) is walking (event times
  independent of physiology, kept when they fall mid-walk)."""
  n = len(tl); cs = np.r_[0, np.cumsum(walking.astype(np.int64))]; i = np.arange(n)
  ok = (i - pre - u >= 60) & (i + 90 < n)
  good = np.zeros(n, bool); good[ok] = (cs[i[ok] - u] - cs[i[ok] - u - pre]) == pre
  cand = np.flatnonzero(good); rng.shuffle(cand)
  out = []
  for j in cand:
    if all(abs(j - q) >= gap for q in out):
      out.append(int(j))
    if len(out) >= k:
      break
  return sorted(int(tl.minutes[j]) for j in out)


class WalkingNull(unittest.TestCase):
  def test_mid_walk_null_is_calibrated(self):
    """sig-1 matched one minute of context and made 57-77 % of random walking onsets 'established'."""
    p = []
    for seed in range(40):
      tl, walking = make_walking_timeline(days=14, seed=300 + seed)
      on = uniform_walk_onsets(tl, walking, 10, np.random.default_rng(seed))
      r, _, _ = engine.run(tl, Evidence("T", events_at(on, unc=0), owner=f"w{seed}"), generated_at=1,
                           forward_eval=False)
      p.append(r["signatures"][0]["p_value"])
      self.assertNotEqual(r["status"], "insufficient_events")
    p = np.array([1.0 if v is None else v for v in p])
    self.assertLessEqual(np.mean(p < 0.05), 0.10)


class ChangeFamily(unittest.TestCase):
  def test_movement_accompanied_event_is_found_by_the_change_family(self):
    """HR +15 bpm with steps and motion (the event makes the person move). Context normalisation attributes most
    of the HR rise to walking; the change-from-before family must still show it in physical units."""
    tl = make_timeline(days=18, seed=31)
    onsets = event_onsets(tl, 12, np.random.default_rng(31))
    t2 = plant_hr(tl, onsets, amp=15.0)
    for s in onsets:
      i = int(tl.index(s))
      t2.cols["steps"][i:i + 10] = 90.0
      t2.cols["motion"][i:i + 10] = 0.25; t2.cols["motion_p90"][i:i + 10] = 0.35
    r, _, _ = engine.run(t2, Evidence("T", events_at(onsets), owner="o"), generated_at=1, forward_eval=False)
    self.assertIn(r["status"], ("emerging", "established"))
    change = [f for f in r["signatures"][0]["findings"] if f["basis"] == "change_from_before" and f["channel"] == "hr"]
    self.assertTrue(change, r["signatures"][0]["findings"])
    self.assertEqual(change[0]["direction"], "up")
    self.assertGreater(change[0]["change"], 8)
    self.assertIn("from before onset", change[0]["text"])
    self.assertEqual(validate(r), [])

  def test_change_family_skipped_for_large_uncertainty(self):
    tl = make_timeline(days=14, seed=32)
    onsets = event_onsets(tl, 8, np.random.default_rng(32))
    tl = plant_hr(tl, onsets, amp=15.0)
    ctx = classify(tl)
    m = fit_models(tl, ctx, Evidence("T", events_at(onsets, unc=60), owner="o"), "context", None,
                   np.random.default_rng(0))
    self.assertTrue(np.isnan(m.built["paired"].D_change).all())
    m = fit_models(tl, ctx, Evidence("T", events_at(onsets, unc=15), owner="o"), "context", None,
                   np.random.default_rng(0))
    self.assertTrue(np.isfinite(m.built["paired"].D_change[:, 0]).any())


class Availability(unittest.TestCase):
  def test_caregiver_spans_recorded_after_the_cutoff_are_not_used(self):
    tl = make_timeline(days=16, seed=33)
    onsets = event_onsets(tl, 10, np.random.default_rng(33))
    tl = plant_hr(tl, onsets, amp=12.0)
    cutoff = float(onsets[6] - 3600)
    span = (float(onsets[2]) + 6 * 3600, float(onsets[2]) + 9 * 3600)      # inside the training period
    late = Evidence("T", events_at(onsets), owner="o", observations=[span + (cutoff + 86400,)],
                    negatives=[span + (cutoff + 10,)], rejected=[span + (cutoff + 5,)])
    early = Evidence("T", events_at(onsets), owner="o", observations=[span + (cutoff - 10,)])
    none = Evidence("T", events_at(onsets), owner="o")
    self.assertEqual(preferred_spans(late, cutoff), [])
    self.assertEqual(preferred_spans(early, cutoff), [span])
    ctx = classify(tl)
    a = fit_models(tl, ctx, late, "context", cutoff, rng_for("o", "T", cutoff))
    b = fit_models(tl, ctx, none, "context", cutoff, rng_for("o", "T", cutoff))
    c = fit_models(tl, ctx, early, "context", cutoff, rng_for("o", "T", cutoff))
    self.assertEqual(a.info["labelled_negative_minutes"], 0)
    self.assertEqual(a.built["controls"], b.built["controls"])
    np.testing.assert_array_equal(a.scores["logistic"], b.scores["logistic"])
    self.assertGreater(c.info["labelled_negative_minutes"], 0)
    self.assertEqual(a.info["observation_hours"], 0.0); self.assertEqual(c.info["observation_hours"], 3.0)


class ChampionChallenger(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    tl = make_timeline(days=24, seed=34)
    cls.onsets = event_onsets(tl, 16, np.random.default_rng(34))
    cls.tl = plant_hr(tl, cls.onsets, amp=16.0)
    cls.ev = Evidence("T", events_at(cls.onsets, unc=5), owner="o")

  def test_frozen_incumbent_is_scored_on_later_events(self):
    ctx = classify(self.tl)
    cut = float(self.tl.minutes[0] + 86400 * int((self.onsets[8] - self.tl.minutes[0]) // 86400))
    fwd = forward(self.tl, ctx, self.ev, "context", "o", incumbent={"training_cutoff": cut})
    ch = fwd["champion"]
    self.assertTrue(ch["comparable"])
    self.assertEqual(ch["training_cutoff"], int(cut))
    self.assertEqual(ch["events"], sum(1 for s in self.onsets if s >= cut))
    self.assertLessEqual(ch["champion_detected"], ch["events"])
    self.assertLessEqual(ch["challenger_detected"], ch["events"])
    self.assertEqual(fwd["training_cutoff"], int(self.tl.minutes[-1] + 60))
    # The frozen model is exactly the model fitted at the incumbent's cutoff.
    frozen = fit_models(self.tl, ctx, self.ev, "context", cut, rng_for("o", "T", cut, "forward"))
    self.assertTrue(all(e.available <= cut for e in frozen.built["events"]))
    r, _, _ = engine.run(self.tl, self.ev, generated_at=1, incumbent={"training_cutoff": cut})
    self.assertEqual(validate(r), [])
    self.assertEqual(r["retrospective"]["champion"]["training_cutoff"], int(cut))
    self.assertEqual(r["retrospective"]["training_cutoff"], int(self.tl.minutes[-1] + 60))

  def test_promotion_rule(self):
    good = {"logistic": {"events": 8, "recall": 0.75, "detected": 6, "false_alerts_per_day": 0.5}}
    for m in det.METHODS[1:]:
      good[m] = {"events": 8, "recall": 0.25, "false_alerts_per_day": 0.5}
    base = dict(comparable=True, challenger_monitored_days=5.0, champion_monitored_days=5.0, events=6)
    self.assertTrue(promotion(good, dict(base, challenger_detected=5, challenger_false_alerts=1,
                                         champion_detected=4, champion_false_alerts=0))[0])
    self.assertTrue(promotion(good, dict(base, challenger_detected=4, challenger_false_alerts=1,
                                         champion_detected=4, champion_false_alerts=3))[0])
    self.assertFalse(promotion(good, dict(base, challenger_detected=4, challenger_false_alerts=1,
                                          champion_detected=4, champion_false_alerts=1))[0])
    self.assertFalse(promotion(good, dict(base, challenger_detected=3, challenger_false_alerts=0,
                                          champion_detected=4, champion_false_alerts=0))[0])
    self.assertFalse(promotion(good, dict(base, challenger_detected=6, challenger_false_alerts=10,
                                          champion_detected=4, champion_false_alerts=0))[0])   # over budget
    self.assertTrue(promotion(good, None)[0])


class Detectability(unittest.TestCase):
  def test_empirical_recall(self):
    rng = np.random.default_rng(0)
    n = 6 * 1440
    t = 60.0 * np.arange(n)
    s = rng.normal(0, 1, n)
    idx = list(range(500, n - 100, 700))
    neg = np.ones(n, bool)
    for i in idx:
      neg[i - 30:i + 40] = False
    strong = s.copy()
    for i in idx:
      strong[i:i + 10] += 8
    rec, ci, thr, days = det.empirical_recall(t, strong, neg, idx)
    self.assertEqual(rec["1"], 1.0); self.assertGreater(ci["1"][0], 0.7)
    rec0, ci0, _, _ = det.empirical_recall(t, s, neg, idx)
    self.assertLess(rec0["1"], 0.3)
    self.assertLessEqual(rec0["0.5"], rec0["2"])
    short = det.empirical_recall(t[:600], s[:600], neg[:600], [100])
    self.assertIsNone(short[0]["1"])                                   # < 1 day of negative time

  def test_assessment_needs_empirical_recall_and_d(self):
    self.assertEqual(det.assess(3.0, [2.2, 3.5], 10, 8, {"1": 0.6}, {"1": [0.35, 0.8]}), "promising")
    self.assertEqual(det.assess(3.0, [2.2, 3.5], 10, 8, {"1": 0.6}, {"1": [0.25, 0.8]}), "too_weak_for_alerts")
    self.assertEqual(det.assess(3.0, [1.8, 3.5], 10, 8, {"1": 0.9}, {"1": [0.6, 1.0]}), "too_weak_for_alerts")
    self.assertEqual(det.assess(3.0, [2.2, 3.5], 10, 2, {"1": 0.9}, {"1": [0.6, 1.0]}), "insufficient_data")

  def test_logistic_C_is_chosen_inside_each_fold(self):
    tl = make_timeline(days=16, seed=35)
    onsets = event_onsets(tl, 10, np.random.default_rng(35))
    tl = plant_hr(tl, onsets, amp=12.0)
    ctx = classify(tl); ev = Evidence("T", events_at(onsets), owner="o")
    model = fit_models(tl, ctx, ev, "context", None, np.random.default_rng(0))
    calls = []
    real = det.LogisticScorer._choose_C
    with mock.patch.object(det.LogisticScorer, "_choose_C", staticmethod(lambda X, y, g: calls.append(len(y)) or real(X, y, g))):
      out = detectability(tl, ctx, ev, model, np.random.default_rng(1))
    self.assertGreaterEqual(len(calls), 3)                             # one per fold, on fold training data only
    self.assertTrue(all(c < max(calls) * 1.01 for c in calls))
    self.assertEqual(set(out["expected_recall_ci"]), {"0.5", "1", "2"})

  def test_logistic_scores_without_hrv_but_not_without_hr(self):
    tl = make_timeline(days=12, seed=36)
    onsets = event_onsets(tl, 8, np.random.default_rng(36))
    tl = plant_hr(tl, onsets, amp=12.0)
    tl.cols["ln_rmssd"][::2] = np.nan                                 # HRV often missing
    ctx = classify(tl)
    m = fit_models(tl, ctx, Evidence("T", events_at(onsets), owner="o"), "context", None, np.random.default_rng(0))
    s = m.scores["logistic"]
    worn = np.isfinite(m.dev.z["hr"])
    self.assertGreater(np.isfinite(s[worn]).mean(), 0.99)
    self.assertTrue(np.isnan(s[~worn]).all())


class RRAndSqlite(unittest.TestCase):
  def test_rr_beats_follow_ord_within_a_second(self):
    minutes = minute_grid(T0, T0 + 120)
    # Two beats per second; true order (ord) alternates 600/640 smoothly; value order would pair 600 with 600.
    ts = np.repeat(T0 + np.arange(60), 2)
    rr = np.tile([640, 600], 60)
    ordv = np.tile([1, 0], 60)                                         # 600 came first within each second
    s_ord, p_ord, _ = rr_pairs_per_minute(minutes, ts, rr, ord_=ordv)
    expected = 119 * 40.0 ** 2
    self.assertEqual(p_ord[0], 119); self.assertEqual(s_ord[0], expected)
    s_ins, p_ins, _ = rr_pairs_per_minute(minutes, ts, rr)            # no ord: insertion order (640 first)
    self.assertEqual(p_ins[0], 119); self.assertEqual(s_ins[0], expected)
    # Three beats per second whose order within the second (ord) is not their value order.
    ts3 = np.array([T0, T0, T0, T0 + 1, T0 + 1, T0 + 1])
    rr3 = np.array([700, 800, 750, 700, 800, 750]); o3 = np.array([1, 0, 2, 1, 0, 2])
    s3, p3, _ = rr_pairs_per_minute(minutes, ts3, rr3, ord_=o3)       # 800,700,750,800,700,750
    self.assertEqual((p3[0], s3[0]), (5, 2 * 100.0 ** 2 + 3 * 50.0 ** 2))
    s4, _, _ = rr_pairs_per_minute(minutes, ts3, np.sort(rr3.reshape(2, 3), axis=1).ravel(), ord_=np.tile([0, 1, 2], 2))
    self.assertNotEqual(s4[0], s3[0])                                  # value order (sig-1) gives another RMSSD

  def _db(self, d):
    path = os.path.join(d, "whoop.sqlite")
    c = sqlite3.connect(path)
    c.executescript("""
      create table hrSample(deviceId text, ts integer, bpm integer, synced integer default 0);
      create table rrInterval(deviceId text, ts integer, rrMs integer, seq integer default 0, synced integer default 0,
        ord integer, srcChannel integer, tsSuspect integer);
      create table sleepSession(deviceId text, startTs integer, endTs integer);""")
    return path, c

  def test_sqlite_reads_ord_and_matches_prefixed_sleep_sessions(self):
    with tempfile.TemporaryDirectory() as d:
      path, c = self._db(d)
      c.executemany("insert into hrSample values('dev',?,70,0)", [(t,) for t in range(T0, T0 + 600)])
      rows = []
      for t in range(T0, T0 + 600):
        rows += [("dev", t, 750, 0, 0, 1, 5, 0), ("dev", t, 700, 0, 0, 0, 5, 0), ("dev", t, 800, 0, 0, 2, 5, 0)]
      c.executemany("insert into rrInterval values(?,?,?,?,?,?,?,?)", rows)
      c.executemany("insert into sleepSession values(?,?,?)", [("dev-noop", T0, T0 + 180), ("devx", T0 + 300, T0 + 600),
                                                               ("dev", T0 + 420, T0 + 480)])
      c.commit(); c.close()
      tl = load_whoop_sqlite(path, "dev", T0, T0 + 600, 0)
      self.assertEqual(list(tl["asleep"][:3]), [1, 1, 1])               # "dev-noop" belongs to "dev"
      self.assertTrue(np.isnan(tl["asleep"][5]))                         # "devx" does not
      self.assertEqual(tl["asleep"][7], 1)
      self.assertEqual(tl.meta["rr"]["clean"], 1800)


class CliTypeId(unittest.TestCase):
  def test_planted_events_take_the_requested_type(self):
    with tempfile.TemporaryDirectory() as d:
      path = os.path.join(d, "whoop.sqlite")
      c = sqlite3.connect(path)
      c.execute("create table hrSample(deviceId text, ts integer, bpm integer, synced integer default 0)")
      rng = np.random.default_rng(0)
      c.executemany("insert into hrSample values('dev',?,?,0)",
                    [(t, int(65 + 5 * np.sin(t / 3000) + rng.normal(0, 2))) for t in range(T0, T0 + 6 * 86400, 2)])
      c.commit(); c.close()
      out = os.path.join(d, "report.json")
      code = cli.main(["evaluate", "--sqlite", path, "--device", "dev", "--type-id", "seizure", "--inject",
                       "n=4,hr=15,context=any,seed=3", "--no-forward", "--generated-at", "1", "--out", out])
      r = json.load(open(out))
      self.assertEqual(code, 0)
      self.assertEqual(r["type_id"], "seizure")
      self.assertEqual(r["evidence"]["events"], 4)


if __name__ == "__main__":
  unittest.main()
