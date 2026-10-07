"""TimesFM 3.0 forecast-residual scorer (the prototype's best configuration, `mv_cov_lag360 c1024_h30 chanp`).

For a 30-minute window starting at s:
  * context  = the 5 target channels over [s − lag − C, s − lag) (C = 1024 min, lag = 360 min);
  * covariates (motion dyn, steps, asleep) over [s − lag − C, s + 30) — observed, so known through the horizon;
  * forecast lag + 30 minutes, keep the last 30, z = (obs − q50) / ((q90 − q10) / 2.563) per minute.
The lag keeps a shift that began within the last 6 h out of the context, so a slow drift or a sustained step shows
as residual instead of being learned as "normal". Calibration to p happens per user in service.py.
Synthetic result (scratch models/out/analysis_table.txt): AUROC 0.925; per-window FPR ≈ 1 % at p < 0.01.
"""

from __future__ import annotations

import os

import numpy as np

from ..features import COVARIATES, TARGETS


class TimesFMScorer:
  name = "timesfm-3.0"

  def __init__(self, cfg, context: int | None = None, lag: int = 360, horizon: int = 30, batch: int = 2):
    # batch 2: scoring RSS ≈ 2.0 GB with the low-memory loader (2.5 GB at 4) — the unit's MemoryHigh is 2.8 GB.
    if cfg.timesfm_src:
      os.environ.setdefault("TIMESFM_SRC", cfg.timesfm_src)
    os.environ.setdefault("TIMESFM_WEIGHTS", cfg.timesfm_weights)
    from . import tfm_core   # imports torch + timesfm3 (pinned source)
    self.core = tfm_core
    self.fc = tfm_core.load_timesfm(cfg.timesfm_weights, threads=cfg.threads, low_mem=True)
    self.context = context or cfg.context_minutes
    self.lag = lag
    self.horizon = horizon
    self.batch = batch
    self.version = f"timesfm-3.0@43046b85/lag{lag}-c{self.context}-h{horizon}"
    self.history_minutes = self.context + self.lag

  def prepare(self, frame, state) -> None:
    pass                                                 # zero-shot: no per-user state

  def score(self, frame, windows, state=None) -> list[tuple]:
    if not windows:
      return []
    tg = frame.targets().astype(np.float32)              # (U, N)
    cv = frame.covariates().astype(np.float32)           # (W, N)
    index = {int(m): i for i, m in enumerate(frame.minutes)}
    ctxs, pfs, keep = [], [], []
    for w in windows:
      i = index.get(int(w.start))
      if i is None:
        continue
      a = i - self.lag - self.context
      if a < 0 or i + self.horizon > tg.shape[1]:
        continue
      ctx = tg[:, a:i - self.lag]
      if np.isfinite(ctx[0]).mean() < 0.5:                # HR context mostly missing: do not forecast
        continue
      ctxs.append(ctx)
      pfs.append(cv[:, a:i + self.horizon])
      keep.append((w, i))
    if not ctxs:
      return []
    q = self.core.forecast_masked(self.fc, ctxs, self.lag + self.horizon, past_future_covariates=pfs,
                                  batch_size=self.batch)[:, :, self.lag:]      # (B, U, H, 9)
    out = []
    for (w, i), qi in zip(keep, q):
      obs = tg[:, i:i + self.horizon]
      z = self.core.quantile_z(obs, qi, sigma_floor=_SIGMA_FLOOR)
      out.append((w, z))
    return out


# Per-channel sigma floors in channel units (hr bpm, ln-RMSSD, °C, /min, %): a near-zero predictive spread must not
# turn a tiny deviation into an extreme z.
_SIGMA_FLOOR = np.array([1.0, 0.05, 0.05, 0.3, 0.5], dtype=np.float32)[:, None]
assert len(_SIGMA_FLOOR) == len(TARGETS) and len(COVARIATES) == 3
