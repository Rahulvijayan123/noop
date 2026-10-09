import os
import sqlite3
import tempfile
import unittest

import numpy as np

from personal_events.timeline import (ACTIVITY_CLASSES, assemble, grouped_mean_p90, hr_per_minute, load_whoop_sqlite,
                                      minute_grid, rr_pairs_per_minute, steps_per_minute)

T0 = 1_790_000_000 - 1_790_000_000 % 86400


class PerMinute(unittest.TestCase):
  def setUp(self):
    self.minutes = minute_grid(T0, T0 + 10 * 60)

  def test_hr_needs_30_seconds_and_range(self):
    ts = np.r_[T0 + np.arange(40), T0 + 60 + np.arange(20), T0 + 120 + np.arange(60)]
    bpm = np.r_[np.full(40, 70), np.full(20, 80), np.full(59, 90), 300]
    mean, hi, lo, n = hr_per_minute(self.minutes, ts, bpm)
    self.assertEqual(mean[0], 70); self.assertTrue(np.isnan(mean[1]))       # 20 s < 30 s
    self.assertEqual(n[2], 59); self.assertEqual(hi[2], 90)                  # 300 bpm dropped
    self.assertTrue(np.isnan(mean[3:]).all())                                # missing stays NaN, never 0

  def test_motion_mean_and_p90_match_numpy(self):
    rng = np.random.default_rng(0)
    ts = T0 + np.sort(rng.integers(0, 180, 300)); v = rng.random(300)
    mean, p90 = grouped_mean_p90(self.minutes, ts, v)
    for m in range(3):
      sel = (ts - T0) // 60 == m
      self.assertAlmostEqual(mean[m], v[sel].mean()); self.assertAlmostEqual(p90[m], np.percentile(v[sel], 90))
    self.assertTrue(np.isnan(mean[3]))

  def test_steps_wrap_reset_and_gaps(self):
    ts = T0 + np.array([0, 30, 59, 61, 90, 125, 150, 600])
    counter = np.array([65530, 65534, 3, 5, 8, 8, 2, 50])                    # wrap, then a reset to 2
    s = steps_per_minute(self.minutes, ts, counter)
    self.assertEqual(s[0], 4 + 5)                                           # 65530->65534->3 wraps mod 2^16
    self.assertEqual(s[1], 2 + 3)
    self.assertTrue(np.isnan(s[2]))                                         # reset 8 -> 2: implausible jump
    self.assertTrue(np.isnan(s[10 - 1]) or len(s) < 10)
    self.assertTrue(np.isnan(s[5]))                                         # no samples: unknown, not 0

  def test_rr_cleaning_malik_and_channel_pinning(self):
    ts = T0 + np.arange(0, 60)
    rr = np.full(60, 800); rr[10] = 1200                                    # Malik rejects the 50 % jump pairs
    s, p, _ = rr_pairs_per_minute(self.minutes, ts, rr)
    self.assertEqual(p[0], 59 - 2)
    # channel 7 beats are dropped in a minute where channel 5 is present
    ts2 = np.r_[ts, ts]; rr2 = np.r_[np.full(60, 800), np.full(60, 900)]
    ch = np.r_[np.full(60, 5), np.full(60, 7)]
    s2, p2, _ = rr_pairs_per_minute(self.minutes, ts2, rr2, channel=ch)
    self.assertEqual(p2[0], 59); self.assertEqual(s2[0], 0.0)
    # suspect and out-of-range beats are dropped; fill value 500 is dropped at low HR
    sus = np.zeros(60); sus[:30] = 1
    _, p3, _ = rr_pairs_per_minute(self.minutes, ts, np.full(60, 800), suspect=sus)
    self.assertEqual(p3[0], 29)
    _, p4, _ = rr_pairs_per_minute(self.minutes, ts, np.full(60, 500), hr_mean=np.full(len(self.minutes), 70.0))
    self.assertEqual(p4[0], 0)


class Assemble(unittest.TestCase):
  def build(self, motion_value, n=6, pairs=40.0):
    minutes = minute_grid(T0, T0 + n * 60)
    hr = np.full(n, 60.0)
    sumsq = np.full(n, pairs * 30.0 ** 2); p = np.full(n, pairs)
    mot = np.full(n, motion_value)
    return assemble(minutes, 0, hr=(hr, hr, hr, np.full(n, 60.0)), rr=(sumsq, p), motion=(mot, mot),
                    steps=np.zeros(n))

  def test_rmssd_only_when_still(self):
    still = self.build(0.01)
    self.assertTrue(np.isnan(still["ln_rmssd"][0]))                         # needs 2 minutes of window
    self.assertAlmostEqual(still["ln_rmssd"][3], np.log(30.0))
    moving = self.build(0.2)
    self.assertTrue(np.isnan(moving["ln_rmssd"]).all())
    self.assertTrue(moving["motion_artifact"][1:].all())

  def test_rmssd_needs_30_pairs(self):
    tl = self.build(0.01, pairs=10.0)                                       # 2-min window has 20 pairs
    self.assertTrue(np.isnan(tl["ln_rmssd"]).all())

  def test_missing_inputs_stay_nan(self):
    minutes = minute_grid(T0, T0 + 300)
    tl = assemble(minutes, 0)
    for col in ("hr", "ln_rmssd", "motion", "steps", "temp", "temp_detr", "resp", "asleep"):
      self.assertTrue(np.isnan(tl[col]).all(), col)
    self.assertFalse(tl["wear"].any())

  def test_wrist_off_and_activity_at_midpoint(self):
    minutes = minute_grid(T0, T0 + 600)
    n = len(minutes); hr = np.full(n, 60.0)
    act = dict(start=[T0, T0 + 300], end=[T0 + 300, T0 + 600], cls=["walking", "stationary"], conf=[0.9, 0.8],
               posture=[None, '{"recumbent": 0.8, "seated_likely": 0.2}'], sleep=["awake", "awake"],
               wear=["on_wrist", "on_wrist"], resp=[15.0, None])
    tl = assemble(minutes, 0, hr=(hr, hr, hr, np.full(n, 60.0)), wrist=[(T0 + 130, False), (T0 + 250, True)],
                  activity=act)
    self.assertEqual(ACTIVITY_CLASSES[tl["activity"][0]], "walking")
    self.assertEqual(ACTIVITY_CLASSES[tl["activity"][6]], "stationary")
    self.assertEqual(tl["posture"][6], 0)                                   # recumbent
    self.assertEqual(list(tl["wear"][:5]), [True, True, False, False, True])
    self.assertEqual(tl["resp"][0], 15.0); self.assertTrue(np.isnan(tl["resp"][6]))


class SqliteLoader(unittest.TestCase):
  def test_reads_read_only_and_scopes_device(self):
    with tempfile.TemporaryDirectory() as d:
      path = os.path.join(d, "whoop.sqlite")
      c = sqlite3.connect(path)
      c.executescript("""
        create table hrSample(deviceId text, ts integer, bpm integer, synced integer default 0);
        create table rrInterval(deviceId text, ts integer, rrMs integer, seq integer default 0, srcChannel integer, tsSuspect integer);
        create table gravitySample(deviceId text, ts integer, x double, y double, z double, dynAccel double);
        create table stepSample(deviceId text, ts integer, counter integer);
        create table skinTempSample(deviceId text, ts integer, raw integer);
        create table sleepStateSample(deviceId text, ts integer, state integer);
        create table event(deviceId text, ts integer, kind text, payloadJSON text);
        create table activityContextInterval(deviceId text, startTs integer, endTs integer, activityClass text,
          confidence double, posture text, sleepState text, wearState text, intensity double, respRateBpm double);
        create table sleepSession(deviceId text, startTs integer, endTs integer);""")
      for t in range(T0, T0 + 300):
        c.execute("insert into hrSample values('a',?,70,0)", (t,))
        c.execute("insert into hrSample values('b',?,120,0)", (t,))
        c.execute("insert into rrInterval values('a',?,?,0,5,0)", (t, 850 + 20 * (t % 2)))
        c.execute("insert into gravitySample values('a',?,0,0,1,0.01)", (t,))
        c.execute("insert into stepSample values('a',?,?)", (t, 100))
        c.execute("insert into skinTempSample values('a',?,3400)", (t,))
        c.execute("insert into sleepStateSample values('a',?,?)", (t, 2 if t < T0 + 120 else 0))
      c.execute("insert into activityContextInterval values('a',?,?,'sitting',0.9,'seated_likely','awake','on_wrist',0,16)",
                (T0 + 120, T0 + 300))
      c.commit(); c.close()
      mtime = os.path.getmtime(path)
      tl = load_whoop_sqlite(path, "a", T0, T0 + 300, 0)
      self.assertEqual(os.path.getmtime(path), mtime)
      self.assertEqual(list(tl["hr"]), [70.0] * 5)
      self.assertEqual(list(tl["asleep"]), [1, 1, 0, 0, 0])
      self.assertAlmostEqual(tl["temp"][0], 34.0)
      self.assertEqual(tl["steps"][1], 0.0)
      self.assertTrue(np.isfinite(tl["ln_rmssd"][2]))
      self.assertEqual(tl["resp"][3], 16.0)
      with self.assertRaises(sqlite3.OperationalError):
        sqlite3.connect("file:" + path + "?mode=ro", uri=True).execute("insert into hrSample values('a',1,1,0)")


if __name__ == "__main__":
  unittest.main()
