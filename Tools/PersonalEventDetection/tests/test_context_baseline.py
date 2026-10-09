import unittest

import numpy as np

from personal_events.baseline import FLOORS, Normalizer, fit_mask
from personal_events.context import C, CONTEXTS, GROUP_OF_CODE, classify, event_context, pre_window
from personal_events.timeline import assemble, minute_grid
from synth import T0, make_timeline


def tl_with(classes, postures=None, motion=None, steps=None, asleep=None):
  n = len(classes)
  minutes = minute_grid(T0, T0 + n * 60)
  hr = np.full(n, 60.0)
  act = dict(start=[T0 + 60 * i for i in range(n)], end=[T0 + 60 * (i + 1) for i in range(n)],
             cls=list(classes), conf=[0.9] * n, posture=list(postures or [None] * n), sleep=["awake"] * n,
             wear=["on_wrist"] * n, resp=[None] * n)
  mot = np.full(n, np.nan) if motion is None else np.asarray(motion, float)
  return assemble(minutes, 0, hr=(hr, hr, hr, np.full(n, 60.0)), activity=act, motion=(mot, mot),
                  steps=None if steps is None else np.asarray(steps, float),
                  sleep_frac=None if asleep is None else np.asarray(asleep, float))


class ContextMapping(unittest.TestCase):
  def test_classes_map_to_contexts(self):
    want = {"walking": "walking", "brisk_walking": "walking", "running": "active", "cycling": "active",
            "vigorous_activity": "active", "light_activity": "active", "sitting": "still_seated",
            "sitting_desk": "still_seated", "lying_down": "still_supine", "standing": "still_upright",
            "sleeping": "asleep", "off_wrist": "off"}
    for cls, ctx in want.items():
      code = classify(tl_with(["unknown"] * 40 + [cls] + ["unknown"] * 40)).code[40]
      self.assertEqual(CONTEXTS[code], ctx, cls)

  def test_stationary_uses_posture(self):
    tl = tl_with(["stationary"] * 4, ["recumbent", "seated_likely", "upright_stationary", None])
    self.assertEqual([CONTEXTS[c] for c in classify(tl).code],
                     ["still_supine", "still_seated", "still_upright", "still_unknown"])

  def test_sensor_fallback_and_recovery(self):
    n = 50
    motion = np.full(n, 0.01); steps = np.zeros(n)
    motion[5:15] = 0.3                  # 10 active minutes -> 30 min recovery
    steps[40:42] = 60; motion[40:42] = 0.08
    tl = tl_with(["unknown"] * n, motion=motion, steps=steps)
    ctx = classify(tl)
    self.assertEqual(CONTEXTS[ctx.code[0]], "still_unknown")
    self.assertEqual(CONTEXTS[ctx.code[10]], "active")
    self.assertTrue(all(CONTEXTS[c] == "recovery" for c in ctx.code[15:40]))
    self.assertEqual(CONTEXTS[ctx.code[40]], "walking")
    self.assertEqual(ctx.minutes_since_exertion[20], 6)
    self.assertTrue(np.isnan(ctx.minutes_since_exertion[0]))

  def test_asleep_overrides_and_bands(self):
    tl = tl_with(["sitting"] * 3, asleep=[1, 0, np.nan])
    ctx = classify(tl)
    self.assertEqual([CONTEXTS[c] for c in ctx.code], ["asleep", "still_seated", "still_seated"])
    self.assertEqual(ctx.band[0], 0)

  def test_event_context_excludes_the_uncertainty(self):
    # 20 min seated, then lying from minute 20 (the event, logged 3 min late at minute 23 with u = 5)
    tl = tl_with(["sitting"] * 20 + ["lying_down"] * 20)
    ctx = classify(tl)
    dom, share, last = event_context(ctx, 23, 5)                 # window [3, 18): all seated
    self.assertEqual((dom, share), (C["still_seated"], 1.0))
    dom0, _, _ = event_context(ctx, 23, 0)                       # without uncertainty the lying minutes count
    self.assertEqual(dom0, C["still_seated"])
    dom_late, share_late, _ = event_context(ctx, 38, 0)          # [23, 38): all lying
    self.assertEqual((dom_late, share_late), (C["still_supine"], 1.0))
    self.assertEqual(event_context(ctx, 10, 5)[0], -1)            # window leaves the timeline
    for u in (0, 5, 15):
      pw = pre_window(ctx, u)
      for i in range(len(tl)):
        d, sh, lg = event_context(ctx, i, u)
        self.assertEqual((int(pw.dominant[i]), round(float(pw.share[i]), 9), int(pw.last_group[i])),
                         (d, round(sh, 9), lg), (u, i))


class Baseline(unittest.TestCase):
  def setUp(self):
    self.tl = make_timeline(days=6, seed=3)
    self.ctx = classify(self.tl)

  def test_shrinkage_weights(self):
    tl, ctx = self.tl, self.ctx
    mask = fit_mask(tl, ctx)
    norm = Normalizer("context").fit(tl, ctx, mask)
    p = norm.params["hr"]
    x = tl["hr"][mask]; codes = ctx.code[mask]; band = ctx.band[mask]
    c, b = C["still_unknown"], 2
    sel_c = codes == c; sel = sel_c & (band == b)
    g = np.median(x); n_c = sel_c.sum(); n_cb = sel.sum()
    ctx_center = n_c / (n_c + 60) * np.median(x[sel_c]) + 60 / (n_c + 60) * g
    want = n_cb / (n_cb + 60) * np.median(x[sel]) + 60 / (n_cb + 60) * ctx_center
    self.assertAlmostEqual(p["center"][c, b], want, places=9)
    self.assertTrue(np.isnan(p["center"][C["off"]]).all())

  def test_fit_is_causal(self):
    tl, ctx = self.tl, self.ctx
    cutoff = float(tl.minutes[3 * 1440])
    a = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx, cutoff=cutoff))
    t2 = tl.copy(); t2.cols["hr"][3 * 1440:] += 40                   # change only the future
    b = Normalizer("context").fit(t2, ctx, fit_mask(t2, ctx, cutoff=cutoff))
    np.testing.assert_array_equal(a.params["hr"]["center"], b.params["hr"]["center"])

  def test_event_margin_excluded(self):
    tl, ctx = self.tl, self.ctx
    s = float(tl.minutes[2000])
    mask = fit_mask(tl, ctx, [(s, s + 600)])
    self.assertFalse(mask[2000 - 119:2010 + 119].any())
    self.assertTrue(mask[2000 - 125:2000 - 121].any() or not tl["wear"][2000 - 125:2000 - 121].any())

  def test_no_baseline_abstains_and_floors(self):
    tl, ctx = self.tl, self.ctx
    mask = np.zeros(len(tl), bool); mask[:10] = True                 # too few minutes
    dev = Normalizer("context").fit(tl, ctx, mask).transform(tl, ctx)
    self.assertTrue(np.isnan(dev.z["hr"]).all())
    t2 = tl.copy(); t2.cols["hr"][:] = 60.0                           # zero variance -> floor
    norm = Normalizer("raw").fit(t2, ctx, fit_mask(t2, ctx))
    self.assertEqual(norm.params["hr"]["global"][1], FLOORS["hr"])
    self.assertTrue(np.isnan(Normalizer("raw").fit(tl, ctx, fit_mask(tl, ctx)).transform(tl, ctx).z["resp"]).all())

  def test_sparse_context_borrows_parent_baseline(self):
    tl = self.tl.copy()
    ctx = classify(tl)
    code = ctx.code.copy()
    walk = np.flatnonzero(code == C["walking"])
    code[walk[:5]] = C["active"]                                   # 5 active minutes: too few of their own
    ctx.code = code
    norm = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx))
    p = norm.params["hr"]
    self.assertEqual(p["fallback"].get("active"), "walking")
    np.testing.assert_allclose(p["center"][C["active"]], p["center"][C["walking"]])
    self.assertTrue(np.isfinite(norm.transform(tl, ctx).z["hr"][walk[:5]]).all())
    self.assertIn("hr", norm.describe()["fallback"])
    code2 = ctx.code.copy(); code2[code2 == C["walking"]] = C["unknown"]; code2[walk[:5]] = C["active"]
    ctx.code = code2
    p2 = Normalizer("context").fit(tl, ctx, fit_mask(tl, ctx)).params["hr"]
    self.assertEqual(p2["fallback"].get("active"), "awake")      # no walking baseline either -> awake pooled

  def test_response_model_used_only_when_it_helps(self):
    tl, ctx = self.tl, self.ctx
    norm = Normalizer("context+response").fit(tl, ctx, fit_mask(tl, ctx))
    self.assertIn("response_used", norm.info)
    t2 = tl.copy(); t2.cols["motion"][:] = np.nan
    n2 = Normalizer("context+response").fit(t2, ctx, fit_mask(t2, ctx))
    self.assertFalse(n2.info["response_used"])
    np.testing.assert_allclose(n2.transform(t2, ctx).z["hr"],
                               Normalizer("context").fit(t2, ctx, fit_mask(t2, ctx)).transform(t2, ctx).z["hr"])


if __name__ == "__main__":
  unittest.main()
