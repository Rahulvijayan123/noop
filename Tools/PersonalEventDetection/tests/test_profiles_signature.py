import unittest

import numpy as np

from personal_events import profiles as prof
from personal_events import signature as sig
from personal_events.baseline import Normalizer, fit_mask
from personal_events.context import C, GROUP_OF_CODE, classify, event_context, pre_window
from personal_events.evidence import Evidence
from personal_events import engine
from synth import event_onsets, events_at, make_timeline, plant_hr


def prepared(days=16, seed=1, n=10, amp=15.0, unc=0.0, shift=0):
  tl = make_timeline(days=days, seed=seed)
  onsets = event_onsets(tl, n, np.random.default_rng(seed))
  planted = plant_hr(tl, [s + 60 * shift for s in onsets], amp=amp)
  return planted, onsets, events_at(onsets, unc=unc)


class MatchedControls(unittest.TestCase):
  def test_controls_follow_every_rule(self):
    tl, onsets, events = prepared(n=8)
    ctx = classify(tl)
    excl = [(e.start, e.end) for e in events]
    dev = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx, excl)).transform(tl, ctx)
    built = prof.build(tl, ctx, dev, events, exclusions=excl, preferred_spans=[], rng=np.random.default_rng(0))
    tod = ((tl.minutes + tl.tz_offset_s) % 86400) // 60
    self.assertGreaterEqual(len(built["events"]), 6)
    for e, raw_i, cs, width in zip(built["events"], built["raw_idx"], built["raw_controls"], built["control_window_min"]):
      u = int(e.uncertainty_min)
      dom, _, last = event_context(ctx, raw_i, u)
      pw = pre_window(ctx, u)
      self.assertTrue(3 <= len(cs) <= 8)
      for j in cs:
        self.assertEqual(pw.dominant[j], dom)                            # same pre-window context ...
        self.assertGreaterEqual(pw.share[j], 0.7)                          # ... with share >= 0.7
        self.assertEqual(pw.last_group[j], last)
        d = abs(int(tod[j]) - int(tod[raw_i])); self.assertLessEqual(min(d, 1440 - d), width)
        self.assertNotEqual(tl.local_day[j], tl.local_day[raw_i])          # another local day
        self.assertTrue(all(abs(tl.minutes[j] - s) >= 2 * 3600 - 60 for s in onsets))
        self.assertTrue(tl["wear"][j])
        self.assertGreaterEqual(np.isfinite(tl["hr"][j - 30:j + 31]).mean(), 0.7)

  def test_fewer_than_three_controls_drops_the_event(self):
    tl, onsets, events = prepared(n=4)
    ctx = classify(tl)
    excl = [(e.start, e.end) for e in events]
    dev = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx, excl)).transform(tl, ctx)
    # Every minute but one day is excluded: at most two controls (>= 61 min apart in a +/- 60 min window) exist
    # for an event at that time of day once widening is exhausted... so block all days instead.
    blocked = excl + [(float(tl.minutes[0]), float(tl.minutes[-1]))]
    built = prof.build(tl, ctx, dev, events, exclusions=blocked, preferred_spans=[], rng=np.random.default_rng(0))
    self.assertEqual(built["events"], [])
    self.assertEqual({r for _, r in built["dropped"]}, {"fewer than 3 matched controls"})
    r, _, _ = engine.run(tl, Evidence("T", events, positive_reviews=[(float(tl.minutes[0]), float(tl.minutes[-1]))],
                                      owner="o"), generated_at=1, forward_eval=False)
    self.assertEqual(r["evidence"]["events_used"], 0)
    self.assertEqual(r["evidence"]["events_dropped"], {"fewer than 3 matched controls": len(events)})

  def test_daily_fixed_time_events_get_controls_by_widening(self):
    tl = make_timeline(days=14, seed=21)
    days = np.unique(tl.local_day)
    onsets = [int(d * 86400 + 14 * 3600) for d in days]                    # every day at 14:00
    events = events_at(onsets, unc=0)
    tl = plant_hr(tl, onsets, amp=15.0)
    ctx = classify(tl)
    excl = [(e.start, e.end) for e in events]
    dev = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx, excl)).transform(tl, ctx)
    built = prof.build(tl, ctx, dev, events, exclusions=excl, preferred_spans=[], rng=np.random.default_rng(0))
    self.assertGreaterEqual(len(built["events"]), 10)
    self.assertTrue(all(w > 60 for w in built["control_window_min"]))     # +/- 60 min is blocked by the +/- 2 h rule
    r, _, _ = engine.run(tl, Evidence("T", events, owner="o"), generated_at=1, forward_eval=False)
    self.assertTrue(all(w in (120, 240) for w in r["signatures"][0]["control_time_window_min"]))
    self.assertEqual(len(r["signatures"][0]["control_time_window_min"]), len(r["signatures"][0]["event_ids"]))

  def test_preferred_time_used_first(self):
    tl, onsets, events = prepared(n=4)
    ctx = classify(tl)
    excl = [(e.start, e.end) for e in events]
    dev = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx, excl)).transform(tl, ctx)
    # Observation periods at this time of day on half of the other days: those days must be used first.
    obs = [(float(s) + d * 86400 - 5 * 3600, float(s) + d * 86400 + 5 * 3600) for s in onsets[:1]
           for d in range(-3, 13, 2) if d]
    built = prof.build(tl, ctx, dev, events[:1], exclusions=excl, preferred_spans=obs, rng=np.random.default_rng(0),
                       align=False)
    self.assertEqual(len(built["events"]), 1)
    self.assertGreaterEqual(built["preferred"][0], min(3, len(built["controls"][0])))


class Alignment(unittest.TestCase):
  def test_realigns_within_uncertainty_only(self):
    """Logged onsets jittered by -4..+4 min around the true onsets: alignment to the leave-one-out mean profile
    undoes the relative jitter, and never moves an onset further than its stated uncertainty."""
    tl = make_timeline(days=16, seed=1)
    true = event_onsets(tl, 10, np.random.default_rng(1))
    tl = plant_hr(tl, true, amp=25.0)
    jitter = np.array([-4, 3, 0, 4, -2, 2, -3, 1, -1, 4])
    logged = [t + 60 * int(j) for t, j in zip(true, jitter)]
    ctx = classify(tl)
    for unc in (5.0, 2.0, 0.0):
      events = events_at(logged, unc=unc)
      excl = [(e.start, e.end) for e in events]
      dev = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx, excl)).transform(tl, ctx)
      built = prof.build(tl, ctx, dev, events, exclusions=excl, preferred_spans=[], rng=np.random.default_rng(0))
      shifts = np.array(built["shift"])
      self.assertTrue((np.abs(shifts) <= unc).all(), (unc, shifts))
      if unc == 5.0:
        # Relative jitter is undone up to one common offset (the template is the blurred mean of the others).
        residual = shifts + jitter
        self.assertGreaterEqual(np.mean(np.abs(residual - np.median(residual)) <= 1), 0.8, shifts)
        self.assertLess(np.std(residual), np.std(jitter) / 2)
      if unc == 0.0:
        self.assertTrue((shifts == 0).all())

  def test_no_alignment_below_four_events(self):
    tl, onsets, _ = prepared(n=3, amp=25.0, shift=4)
    ctx = classify(tl)
    events = events_at(onsets, unc=5.0)
    dev = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx)).transform(tl, ctx)
    built = prof.build(tl, ctx, dev, events, exclusions=[], preferred_spans=[], rng=np.random.default_rng(0))
    self.assertEqual(built["shift"], [0, 0, 0])


class Statistics(unittest.TestCase):
  def test_planted_effect_recovered(self):
    tl, onsets, events = prepared(n=12, amp=15.0)
    report, diag, _ = engine.run(tl, Evidence("T", events, owner="o"), generated_at=1, forward_eval=False)
    s = report["signatures"][0]
    self.assertEqual(report["status"], "established")
    top = next(f for f in s["findings"] if f["basis"] != "joint")
    self.assertEqual((top["channel"], top["direction"], top["window"]), ("hr", "up", [0, 5]))
    self.assertGreater(top["change"], 9); self.assertLess(top["change"], 21)
    lo, hi = top["change_ci"]; self.assertTrue(lo <= 15 <= hi + 3)
    bases = {f["basis"] for f in s["findings"] if f["channel"] == "hr" and f["basis"] != "joint"}
    self.assertEqual(bases, {"change_from_before", "vs_usual_for_context"})
    for f in s["findings"]:
      if f["basis"] == "joint":
        continue
      if f["basis"] == "change_from_before":
        self.assertIn("from before onset", f["text"])
      else:
        self.assertIn("usual for the activity and time of day", f["text"])
    mean = np.array(s["profile"]["channels"]["hr"]["mean"], dtype=float)
    self.assertEqual(int(np.nanargmax(mean)) - 30 in range(0, 10), True)
    self.assertAlmostEqual(s["p_min_possible"], 2 / 2 ** 12, places=6)
    self.assertIn(f"{top['events_with_data']} of {top['events_with_data']} events", top["text"])

  def test_day_clustered_null_is_calibrated(self):
    rng = np.random.default_rng(7)
    rejections, event_level = 0, 0
    runs = 300
    for _ in range(runs):
      days = np.repeat(np.arange(8), 2)                                 # two events per day share the day state
      day_state = rng.normal(0, 1, (8, 1))[days]
      D = day_state + rng.normal(0, 0.5, (16, 12))
      t = sig.global_test(D, days, rng)
      rejections += t["p"] < 0.05
      event_level += sig.global_test(D, np.arange(16), rng)["p"] < 0.05
    self.assertLessEqual(rejections / runs, 0.07)
    self.assertGreater(event_level / runs, rejections / runs)          # ignoring days is anti-conservative

  def test_p_min_and_exactness(self):
    rng = np.random.default_rng(0)
    D = np.abs(rng.normal(3, 0.1, (6, 4)))                              # every event in the same direction
    t = sig.global_test(D, np.arange(6), rng)
    self.assertTrue(t["exact"]); self.assertAlmostEqual(t["p"], 2 / 2 ** 6)
    self.assertAlmostEqual(t["p_min_possible"], 2 / 2 ** 6)
    t = sig.global_test(np.abs(rng.normal(3, 0.1, (14, 2))), np.arange(14), rng)
    self.assertFalse(t["exact"])

  def test_cell_p_values_are_family_wise(self):
    rng = np.random.default_rng(0)
    D = rng.normal(0, 1, (8, 12)); D[:, 3] += 3
    t = sig.global_test(D, np.arange(8), rng)
    self.assertEqual(t["cell"], 3)
    self.assertAlmostEqual(t["p_cells"][3], t["p"])
    self.assertTrue((t["p_cells"] >= t["p"] - 1e-12).all())
    self.assertGreater(np.median(np.delete(t["p_cells"], 3)), 0.3)

  def test_status_rules(self):
    self.assertEqual(sig.decide_status(2, 2, None, "not_yet_testable"), "insufficient_events")
    self.assertEqual(sig.decide_status(4, 2, None, "not_yet_testable"), "individual_context")
    self.assertEqual(sig.decide_status(5, 5, 0.0625, "not_yet_testable"), "individual_context")
    self.assertEqual(sig.decide_status(8, 8, 0.07, "not_yet_testable"), "no_reliable_signature")
    self.assertEqual(sig.decide_status(8, 8, 0.03, "not_yet_testable"), "emerging")
    self.assertEqual(sig.decide_status(8, 8, 0.03, "replicated"), "established")
    self.assertEqual(sig.decide_status(8, 8, 0.03, "failed"), "no_reliable_signature")
    self.assertEqual(sig.decide_status(8, 8, 0.4, "not_yet_testable"), "no_reliable_signature")
    self.assertEqual(sig.decide_status(8, 4, 0.4, "not_yet_testable"), "individual_context")

  def test_status_transitions_with_more_events(self):
    tl = make_timeline(days=20, seed=4)
    onsets = event_onsets(tl, 12, np.random.default_rng(4))
    tl = plant_hr(tl, onsets, amp=18.0)
    two_same_day = [onsets[0], onsets[0] + 4 * 3600]
    seen = []
    for chosen in (onsets[:2], two_same_day + [onsets[0] + 8 * 3600], onsets[:6], onsets[:12]):
      events = events_at(chosen)
      r, _, _ = engine.run(tl, Evidence("T", events, owner="o"), generated_at=1, forward_eval=False)
      seen.append(r["status"])
    # 6 events: p = 0.0625 is not below 0.05, so nothing is shown yet; 12 events: significant and replicated.
    self.assertEqual(seen, ["insufficient_events", "individual_context", "individual_context", "established"])

  def test_null_data_gives_no_reliable_signature(self):
    tl = make_timeline(days=20, seed=5)
    onsets = event_onsets(tl, 10, np.random.default_rng(5))
    r, _, _ = engine.run(tl, Evidence("T", events_at(onsets, unc=5), owner="o"), generated_at=1, forward_eval=False)
    self.assertIn(r["status"], ("no_reliable_signature", "emerging"))
    self.assertNotEqual(r["status"], "established")
    if r["status"] == "no_reliable_signature":
      self.assertEqual(r["signatures"][0]["findings"], [])


class Split(unittest.TestCase):
  def test_split_only_when_warranted(self):
    tl = make_timeline(days=26, seed=6)
    rng = np.random.default_rng(6)
    onsets = event_onsets(tl, 24, rng, per_day=1)
    up, down = onsets[0::2], onsets[1::2]
    t2 = plant_hr(plant_hr(tl, up, amp=20.0), down, amp=-20.0)
    r, d, _ = engine.run(t2, Evidence("T", events_at(onsets), owner="o"), generated_at=1, forward_eval=False)
    self.assertEqual(len(r["signatures"]), 2, d["split"])
    dirs = sorted(s["findings"][0]["direction"] for s in r["signatures"])
    self.assertEqual(dirs, ["down", "up"])
    t3 = plant_hr(tl, onsets, amp=20.0)
    r, d, _ = engine.run(t3, Evidence("T", events_at(onsets), owner="o"), generated_at=1, forward_eval=False)
    self.assertEqual(len(r["signatures"]), 1)
    self.assertTrue(d["split"]["tried"])


if __name__ == "__main__":
  unittest.main()
