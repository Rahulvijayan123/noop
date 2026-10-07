"""On-host self-test of the REAL models (no database): python -m frwhoop_anomaly.selftest [--json out.json]

Builds a 2.5-day synthetic minute frame (diurnal HR, nightly sleep with lower HR / higher HRV, walking bouts, a
+20 bpm resting shift in the final 3 hours), then on this machine:
  * loads TimesFM 3.0 and UniTS x128 from the configured pinned paths (same Config as the service);
  * TimesFM: forecasts the last usable rest windows (lag 360, context 1024) → per-window directional HR z;
  * UniTS: prompt-tunes this synthetic user's tokens (reduced budget) and scores the same windows;
  * reports load / inference / training seconds, peak RSS, and whether each model's HR score for a shifted
    window exceeds every unshifted window's (the minimal "does the model see a sustained shift" check).
Exit status 0 only if both models load, return finite scores and separate the shift.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import sys
import tempfile
import time

import numpy as np

from . import candidates as cand
from .config import Config
from .features import MinuteFrame, TARGETS, steady_state
from .state import UserState

T0 = 1_788_220_800   # 2026-09-01T00:00Z


def synthetic_frame(days: float = 2.5, shift_hours: float = 3.0, seed: int = 0) -> MinuteFrame:
  rs = np.random.default_rng(seed)
  n = int(days * 1440)
  t = np.arange(n)
  tod = (t % 1440) / 60.0
  asleep = ((tod >= 23) | (tod < 7)).astype(float)
  walking = np.zeros(n, bool)
  for d in range(int(np.ceil(days))):
    for h in (8.5, 12.5, 18.0):
      s = int(d * 1440 + h * 60)
      walking[s:s + 20] = True
  walking &= asleep == 0
  ar = np.zeros(n)
  for i in range(1, n):
    ar[i] = 0.97 * ar[i - 1] + rs.normal(0, 0.8)
  hr = 62 + 4 * np.sin(2 * np.pi * (tod - 15) / 24) - 8 * asleep + 30 * walking + ar
  rmssd = np.exp(np.log(45) + 0.25 * asleep - 0.4 * walking + rs.normal(0, 0.12, n))
  temp = 33.5 + 0.8 * asleep + rs.normal(0, 0.08, n)
  resp = 14 - 1.5 * asleep + rs.normal(0, 0.6, n)
  shift = t >= n - int(shift_hours * 60)
  hr = hr + 20 * shift
  ctx = np.where(asleep == 1, "asleep", np.where(walking, "walking", "still")).astype(object)
  data = {
    "hr": hr, "ln_rmssd": np.log(rmssd), "temp": temp, "resp": resp, "spo2": np.full(n, np.nan),
    "dyn": np.where(walking, 0.12, 0.01), "steps": np.where(walking, 100.0, 0.0), "asleep": asleep,
    "hr_n": np.full(n, 60.0), "rr_cov": np.ones(n), "wrist_off": np.zeros(n),
  }
  return MinuteFrame(minutes=T0 + 60 * t.astype(np.int64), data=data, context=steady_state(ctx), family="synthetic",
                     counters={"shift_from": int(T0 + 60 * (n - int(shift_hours * 60)))})


def rss_mb() -> float:
  r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
  return r / (1024 * 1024) if sys.platform == "darwin" else r / 1024


def main() -> int:
  ap = argparse.ArgumentParser()
  ap.add_argument("--json", default=None)
  ap.add_argument("--units_windows", type=int, default=200)
  ap.add_argument("--units_epochs", type=int, default=1)
  a = ap.parse_args()
  os.environ.setdefault("FRWHOOP_ANOMALY_DB_URL", "postgresql://selftest-unused")
  cfg = Config.from_env()
  out: dict = {"threads": cfg.threads, "torch_threads": None}
  frame = synthetic_frame()
  shift_from = frame.counters["shift_from"]
  hi = int(frame.minutes[-1]) + 60
  ws = [w for w in cand.windows(frame, hi - 10 * 3600, hi) if w.usable]
  out["windows"] = [{"start": w.start, "shifted": w.start >= shift_from} for w in ws]

  t = time.time()
  from .models.timesfm_scorer import TimesFMScorer
  tfm = TimesFMScorer(cfg)
  out["timesfm_load_s"] = round(time.time() - t, 1)
  out["rss_after_timesfm_mb"] = round(rss_mb())
  import torch
  out["torch_threads"] = torch.get_num_threads()
  out["torch"] = torch.__version__

  t = time.time()
  from .models.units_scorer import UniTSScorer
  units = UniTSScorer(cfg, train_windows=a.units_windows, epochs=a.units_epochs)
  out["units_load_s"] = round(time.time() - t, 1)

  results = {}
  with tempfile.TemporaryDirectory() as tmp:
    st = UserState(tmp, "00000000-0000-4000-8000-000000000000", "00000000-0000-4000-8000-0000000000d0")
    for scorer in (tfm, units):
      t = time.time()
      scorer.prepare(frame, st)
      prep = time.time() - t
      t = time.time()
      raw = scorer.score(frame, ws, state=st)
      infer = time.time() - t
      hr_scores = {int(w.start): float(cand.directional(z)[TARGETS.index("hr")]) for w, z in raw}
      shifted = [v for s, v in hr_scores.items() if s >= shift_from]
      normal = [v for s, v in hr_scores.items() if s < shift_from]
      results[scorer.name] = {
        "version": scorer.version, "prepare_s": round(prep, 1), "infer_s": round(infer, 2),
        "windows_scored": len(raw), "s_per_window": round(infer / max(len(raw), 1), 2),
        "hr_score_shifted": [round(v, 2) for v in shifted], "hr_score_normal": [round(v, 2) for v in normal],
        "finite": bool(raw) and all(np.isfinite(z[TARGETS.index("hr")]).any() for _, z in raw),
        "separates_shift": bool(shifted and normal and min(shifted) > max(normal)),
        "train": getattr(scorer, "last_train", None),
      }
  out["models"] = results
  out["peak_rss_mb"] = round(rss_mb())
  ok = all(r["finite"] and r["separates_shift"] for r in results.values()) and len(results) == 2
  out["ok"] = ok
  text = json.dumps(out, indent=1, default=float)
  print(text)
  if a.json:
    with open(a.json, "w") as fh:
      fh.write(text)
  return 0 if ok else 1


if __name__ == "__main__":
  sys.exit(main())
