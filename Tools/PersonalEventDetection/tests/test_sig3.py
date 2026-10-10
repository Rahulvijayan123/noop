"""sig-3: out-of-fold certification and movement annotation. Synthetic data only."""
import json
import unittest

import numpy as np

from personal_events import detector as det
from personal_events import engine
from personal_events import evaluation as E
from personal_events.baseline import Normalizer, fit_mask
from personal_events.context import C, classify
from personal_events.evidence import Event, Evidence
from personal_events.report import MOVEMENT_NOTE, validate
from synth import event_onsets, events_at, make_timeline, plant_hr


class OutOfFoldCertification(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    tl = make_timeline(days=16, seed=41)
    cls.onsets = event_onsets(tl, 10, np.random.default_rng(41))
    cls.tl = plant_hr(tl, cls.onsets, amp=14.0)
    cls.ctx = classify(cls.tl)
    cls.ev = Evidence("T", events_at(cls.onsets), owner="o")
    cls.model = E.fit_models(cls.tl, cls.ctx, cls.ev, "context", None, np.random.default_rng(0))

  def test_held_out_scores_ignore_the_held_out_days_labels(self):
    """An event on day D is never used by the fold models that score day D."""
    tl, b = self.tl, self.model.built
    day = tl.local_day
    k = 2
    drop_day = int(day[b["idx"][k]])
    # Move that event 3 h later within its own day: the fold assignment (by day) is unchanged.
    idx2 = list(b["idx"]); idx2[k] += 180
    self.assertEqual(int(day[idx2[k]]), drop_day)
    b2 = dict(b, idx=idx2)
    args = (tl, self.ctx, self.ev, "context", None, len(tl))
    neg = np.zeros(0, np.int64)
    s1 = E.oof_scores(*args, b, neg, self.model.scorers["logistic"].C, np.random.default_rng(0))
    s2 = E.oof_scores(*args, b2, neg, self.model.scorers["logistic"].C, np.random.default_rng(0))
    held = day == drop_day
    np.testing.assert_array_equal(s1["logistic"][held], s2["logistic"][held])
    self.assertFalse(np.array_equal(s1["logistic"][~held], s2["logistic"][~held], equal_nan=True))

  def test_thresholds_come_from_out_of_fold_scores(self):
    th = self.model.thresholds["logistic"]
    self.assertIsNotNone(th.enter)
    old = E.CERTIFY_OOF
    try:
      E.CERTIFY_OOF = False
      in_sample = E.fit_models(self.tl, self.ctx, self.ev, "context", None, np.random.default_rng(0))
    finally:
      E.CERTIFY_OOF = old
    self.assertNotEqual(th.enter, in_sample.thresholds["logistic"].enter)

  def test_certification_negative_time_excludes_only_match_windows(self):
    spans = E.certification_exclusions(self.ev)
    e = self.ev.events[0]
    self.assertIn((e.start - e.uncertainty_min * 60 - 300, e.end + 600), spans)
    cert = self.model.cert_mask
    i = int(self.tl.index(e.end + 3600))
    self.assertTrue(cert[i] or not self.tl["wear"][i])                    # 1 h after an event is negative time

  def test_quasi_poisson_bound_widens_for_clustered_alerts(self):
    self.assertAlmostEqual(det.certified_bound(3, 10.0, 1.0), det.poisson_upper(3) / 10.0)
    self.assertGreater(det.certified_bound(3, 10.0, 3.0), det.certified_bound(3, 10.0, 1.0))
    times = 60.0 * np.arange(10 * 1440)
    day_of = (times // 86400).astype(int)
    finite = np.ones(len(times), bool)
    spread = times[np.arange(10) * 1440 + 600]                          # one per day: phi = 1
    clustered = times[np.r_[np.arange(5) * 30 + 600, np.arange(5) * 30 + 3 * 1440 + 600]]
    self.assertEqual(det.dispersion(spread, times, finite, day_of), 1.0)
    self.assertGreater(det.dispersion(clustered, times, finite, day_of), 2.0)

  def test_detectors_abstain_where_the_baseline_has_too_few_days(self):
    tl = self.tl.copy()
    ctx = classify(tl)
    code = ctx.code.copy()
    two_days = np.flatnonzero(np.isin(tl.local_day, np.unique(tl.local_day)[5:7]) & (code == C["still_unknown"]))
    code[two_days] = C["still_seated"]                                    # a context seen on 2 days only
    ctx.code = code
    norm = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx))
    dev = norm.transform(tl, ctx)
    self.assertTrue((dev.support["hr"][two_days] == 2).all())
    scores = E.supported({m: np.ones(len(tl)) for m in det.METHODS}, dev, dev, dev)
    self.assertTrue(np.isnan(scores["logistic"][two_days]).all())
    self.assertTrue(np.isnan(scores["hr_rule_context"][two_days]).all())
    other = np.flatnonzero(code == C["still_unknown"])[:100]
    self.assertTrue((scores["logistic"][other] == 1).all())

  def test_logistic_drops_mostly_absent_channels_and_unobserved_minutes(self):
    lg = self.model.scorers["logistic"]
    self.assertIn("hr", lg.info["channels"])
    self.assertNotIn("resp", lg.info["channels"])                          # no breathing data in this timeline
    F = self.model.features.copy()
    F[:100, [c for c in lg.cols if c >= 3]] = np.nan                       # only HR observed in these minutes
    s = lg.score(F)
    share = np.isfinite(F[:, lg.cols]).mean(axis=1)
    self.assertTrue(np.isnan(s[share < det.MIN_OBSERVED_SHARE]).all())
    self.assertTrue(np.isnan(s[~np.isfinite(F[:, det.HR_FEATURE])]).all())


class MovementAnnotation(unittest.TestCase):
  def _run(self, movement):
    tl = make_timeline(days=18, seed=31)
    onsets = event_onsets(tl, 12, np.random.default_rng(31))
    t2 = plant_hr(tl, onsets, amp=15.0)
    if movement:
      for s in onsets:
        i = int(tl.index(s))
        t2.cols["steps"][i:i + 10] = 90.0
        t2.cols["motion"][i:i + 10] = 0.25; t2.cols["motion_p90"][i:i + 10] = 0.35
    r, _, _ = engine.run(t2, Evidence("T", events_at(onsets), owner="o"), generated_at=1, forward_eval=False)
    return r

  def test_hr_change_with_more_movement_is_marked(self):
    r = self._run(True)
    self.assertEqual(validate(r), [])
    self.assertEqual(r["engine"]["version"], "sig-4")
    hr = [f for f in r["signatures"][0]["findings"] if f["channel"] == "hr" and f["basis"] != "joint"]
    self.assertTrue(hr)
    self.assertTrue(all(f["movement_accompanied"] for f in hr))
    self.assertTrue(all("together with more movement" in f["text"] for f in hr))
    self.assertIn(MOVEMENT_NOTE, r["data_quality"]["notes"])

  def test_hr_change_without_movement_is_not_marked(self):
    r = self._run(False)
    hr = [f for f in r["signatures"][0]["findings"] if f["channel"] == "hr" and f["basis"] != "joint"]
    self.assertTrue(hr)
    self.assertFalse(any(f["movement_accompanied"] for f in hr))
    self.assertNotIn(MOVEMENT_NOTE, r["data_quality"]["notes"])
    bad = json.loads(json.dumps(r))
    next(f for f in bad["signatures"][0]["findings"] if "movement_accompanied" in f)["movement_accompanied"] = "yes"
    self.assertNotEqual(validate(bad), [])


if __name__ == "__main__":
  unittest.main()
