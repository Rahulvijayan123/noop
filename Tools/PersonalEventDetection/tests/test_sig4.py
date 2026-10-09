"""sig-4 joint family: weighted multi-channel deviation, valid under day-level sign flips. Synthetic data only."""
import json
import unittest

import numpy as np

from personal_events import engine
from personal_events import signature as sig
from personal_events.evidence import Evidence
from personal_events.report import validate
from synth import event_onsets, events_at, make_timeline, plant_hr


def cell(d, pseudo, family="level"):
  p = d.shape[1]
  return dict(family=family, window=(0, 5), channels=["hr", "hrv", "temp", "resp", "motion"][:p], units=["bpm"] * p,
              d=d, zdisp=d, phys=d, center=None, pseudo=pseudo)


class JointStatistic(unittest.TestCase):
  def test_all_sign_flip_leaves_t_unchanged_and_weights_follow_the_mean(self):
    rng = np.random.default_rng(0)
    d = rng.normal(0.5, 1, (12, 3)); days = np.arange(12)
    pj = sig.joint_prepare(cell(d, rng.normal(0, 1, (200, 3))), days, 12)
    F = np.vstack([np.ones(12), -np.ones(12)])
    t = sig.joint_t(pj, F)
    self.assertAlmostEqual(t[0], t[1])
    w = sig.joint_weights(pj, (pj["S"].sum(0) / pj["n"])[None, :])[0]
    self.assertAlmostEqual(float(w @ pj["sig"] @ w), 1.0, places=9)

  def test_duplicated_channel_is_not_double_counted(self):
    rng = np.random.default_rng(1)
    base = rng.normal(0.6, 1, (14, 1)); pseudo = rng.normal(0, 1, (300, 1))
    other = rng.normal(0, 1, (14, 1)); pother = rng.normal(0, 1, (300, 1))
    days = np.arange(14)
    one = sig.joint_t(sig.joint_prepare(cell(np.c_[base, other], np.c_[pseudo, pother]), days, 14), np.ones((1, 14)))[0]
    two = sig.joint_t(sig.joint_prepare(cell(np.c_[base, base, other], np.c_[pseudo, pseudo, pother]), days, 14),
                      np.ones((1, 14)))[0]
    self.assertLess(abs(two - one) / one, 0.15)                        # a copy adds ~nothing, not sqrt(2)

  def test_null_with_joint_cells_is_calibrated(self):
    """Day-clustered null: correlated channels, a shared day state, 2 events per day; joint weights refitted in
    every flip keep the max-t family-wise error at the nominal rate."""
    rng = np.random.default_rng(7)
    cov = np.array([[1, .6, 0, 0, .5], [.6, 1, 0, 0, .3], [0, 0, 1, 0, 0], [0, 0, 0, 1, 0], [.5, .3, 0, 0, 1]])
    L = np.linalg.cholesky(cov)
    rej = 0; runs = 300
    for _ in range(runs):
      days = np.repeat(np.arange(8), 2)
      D = (rng.normal(0, 1, (16, 5)) @ L.T) + 0.7 * rng.normal(0, 1, (8, 5))[days]
      D[rng.random(D.shape) < 0.15] = np.nan                           # missing channels
      pseudo = rng.normal(0, 1, (200, 5)) @ L.T
      X = np.c_[D, D * 0.5 + rng.normal(0, 1, D.shape)]                 # some single cells too
      t = sig.global_test(X, days, rng, joint=[cell(D, pseudo)])
      rej += t["p"] < 0.05
    self.assertLessEqual(rej / runs, 0.07)

  def test_joint_raises_power_for_a_two_channel_signal(self):
    rng = np.random.default_rng(3)
    p_joint, p_single = [], []
    for _ in range(40):
      days = np.arange(10)
      D = rng.normal(0, 1, (10, 2)) + 0.75                             # weak in each channel
      pseudo = rng.normal(0, 1, (200, 2))
      p_single.append(sig.global_test(D, days, rng)["p"])
      p_joint.append(sig.global_test(D, days, rng, joint=[cell(D, pseudo)])["p"])
    self.assertLess(np.median(p_joint), np.median(p_single))


class JointFindings(unittest.TestCase):
  def test_tremor_like_plant_gives_a_joint_finding_listing_movement(self):
    tl = make_timeline(days=18, seed=51)
    onsets = event_onsets(tl, 12, np.random.default_rng(51))
    t2 = plant_hr(tl, onsets, amp=6.0)
    for s in onsets:
      i = int(tl.index(s))
      t2.cols["motion"][i:i + 10] += 0.06; t2.cols["motion_p90"][i:i + 10] += 0.1
    r, d, _ = engine.run(t2, Evidence("T", events_at(onsets), owner="o"), generated_at=1, forward_eval=False)
    self.assertEqual(validate(r), [])
    self.assertEqual(r["engine"]["version"], "sig-4")
    joint = [f for f in r["signatures"][0]["findings"] if f.get("basis") == "joint"]
    self.assertTrue(joint, r["signatures"][0]["findings"])
    f = joint[0]
    self.assertEqual(f["unit"], "SD")
    self.assertGreater(f["combined_z_ci"][0], 0)
    chans = {c["channel"] for c in f["channels"]}
    self.assertTrue(chans & {"motion", "steps"} and "hr" in chans, f["channels"])
    self.assertNotIn("movement_accompanied", f)
    self.assertIn("together", f["text"])
    self.assertTrue(any(j["t"] is not None for j in d["signature_detail"][0]["joint"]))
    bad = json.loads(json.dumps(r))
    next(x for x in bad["signatures"][0]["findings"] if x.get("basis") == "joint")["channels"] = [{"channel": "hr"}]
    self.assertNotEqual(validate(bad), [])

  def test_switch_off_restores_sig3_cells(self):
    tl = make_timeline(days=14, seed=52)
    onsets = event_onsets(tl, 9, np.random.default_rng(52))
    old = sig.JOINT_FAMILY
    try:
      sig.JOINT_FAMILY = False
      r, d, _ = engine.run(tl, Evidence("T", events_at(onsets), owner="o"), generated_at=1, forward_eval=False)
    finally:
      sig.JOINT_FAMILY = old
    self.assertEqual(d["signature_detail"][0]["joint"], [])
    self.assertFalse(any(f.get("basis") == "joint" for f in r["signatures"][0]["findings"]))


if __name__ == "__main__":
  unittest.main()
