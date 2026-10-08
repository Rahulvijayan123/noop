"""UniTS x128 conditional-reconstruction scorer (the prototype's best configuration, `x128_ipt_lag chanp`).

The released UniTS x128 self-supervised backbone (MIT) is frozen and shared. Each user gets their own prompt tokens
(10 per variable, ~9 k parameters) prompt-tuned on that user's own minutes through UniTS' imputation path:
  * input  = 1024 minutes of the 5 targets + 3 covariates (dyn, steps, asleep), standardized per user;
  * hidden = the targets over the last 384 minutes (24 patches); covariates stay visible through the end;
  * scored = the last 30 minutes (the window) → signed residual obs − reconstruction per minute and channel.
The visible physiology ends ≈ 6 h before the scored window (same lag rationale as TimesFM), so a shift that began in
the last 6 h is residual, not context. Residuals are robust-standardized with the user's own post-training median/MAD;
p-values come from the per-user empirical calibration in service.py.
Synthetic result (scratch models/out/analysis_table.txt): AUROC 0.95, every event type 8–9/9.

Per-user state (UserState dir): units_prompt.pt (prompt + mask tokens, standardizer, residual scale, metadata).
The prompt is trained once ≥ MIN_TRAIN_HOURS of usable minutes exist, re-trained when the cached history has grown
3× (early life) or the prompt is RETRAIN_DAYS old. A re-train invalidates this model's calibration references.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import time

import numpy as np

from ..features import COVARIATES, TARGETS

log = logging.getLogger("frwhoop_anomaly.units")

WIN = 1024
N_FUTURE = 384
SCORE = 30
MIN_TRAIN_HOURS = 24
RETRAIN_DAYS = 7
N_TRAIN_WINDOWS = 1000
EPOCHS = 3
TRAIN_BATCH = 16


class UniTSScorer:
  name = "units-x128"

  def __init__(self, cfg, train_windows: int = N_TRAIN_WINDOWS, epochs: int = EPOCHS, batch: int = TRAIN_BATCH):
    os.environ.setdefault("UNITS_SRC", cfg.units_src)
    from . import units_core   # imports torch + UniTS model code (pinned source)
    import torch
    self.torch = torch
    self.core = units_core
    self.n_vars = len(TARGETS) + len(COVARIATES)
    self.targets = list(range(len(TARGETS)))
    self.model, self.info = units_core.load_units(cfg.units_ckpt, n_vars=self.n_vars, seq_len=WIN,
                                                  threads=cfg.threads)
    ds = units_core.DATASET
    # The pretrained-mean tokens: every user starts from these, so one user's prompt never leaks into another's.
    self.init_tokens = {"prompt": self.model.prompt_tokens[ds].detach().clone(),
                        "mask": self.model.mask_tokens[ds].detach().clone()}
    self.train_windows = train_windows
    self.epochs = epochs
    self.batch = batch
    self.version = f"units-x128@0e028148/ipt-w{WIN}-f{N_FUTURE}-s{SCORE}"
    self.history_minutes = WIN - SCORE
    self.last_train: dict | None = None

  # ---- per-user prompt -----------------------------------------------------------------------------------------
  def _path(self, state) -> str:
    return os.path.join(state.dir, "units_prompt.pt")

  def _load_user(self, state) -> dict | None:
    path = self._path(state)
    if not os.path.exists(path):
      return None
    try:
      return self.torch.load(path, map_location="cpu", weights_only=True)
    except Exception as e:  # corrupt / old format: retrain
      log.warning("units prompt unreadable (%s); retraining", e)
      return None

  def _apply(self, user: dict | None) -> None:
    ds = self.core.DATASET
    with self.torch.no_grad():
      self.model.prompt_tokens[ds].copy_(user["prompt"] if user else self.init_tokens["prompt"])
      self.model.mask_tokens[ds].copy_(user["mask"] if user else self.init_tokens["mask"])

  @staticmethod
  def _matrix(frame) -> np.ndarray:
    return np.concatenate([frame.targets(), frame.covariates()]).T.astype(np.float32)     # (N, V)

  @staticmethod
  def _usable_span_hours(frame) -> float:
    return float(np.sum(frame.data["hr_n"] >= 30)) / 60.0

  def _needs_training(self, user: dict | None, frame, now: float) -> bool:
    span = self._usable_span_hours(frame)
    if span < MIN_TRAIN_HOURS or len(frame.minutes) < WIN + 60:
      return False
    if user is None:
      return True
    trained_span = float(user["meta"].get("span_hours", 0.0))
    age_days = (now - float(user["meta"].get("trained_at", 0.0))) / 86400.0
    return age_days >= RETRAIN_DAYS or (trained_span < 72 and span >= 3 * trained_span)

  def _train(self, frame, state, now: float) -> dict:
    X = self._matrix(frame)
    mu = np.nanmean(X, 0)
    sd = np.nanstd(X, 0)
    mu = np.where(np.isfinite(mu), mu, 0.0).astype(np.float32)
    sd = np.where(np.isfinite(sd) & (sd > 1e-6), sd, 1.0).astype(np.float32)
    xs = (X - mu) / sd
    # Training windows: HR observed on > 50 % of the window and the hidden block mostly restful (activity is not
    # the physiology we want the prompt to learn as "normal" and the windows the service scores are restful).
    restful = np.isin(np.asarray(frame.context).astype(str), ("still", "asleep"))
    hr_ok = np.isfinite(xs[:, 0])
    starts = np.arange(0, len(xs) - WIN + 1)
    cs_hr = np.concatenate([[0], np.cumsum(hr_ok)])
    cs_rest = np.concatenate([[0], np.cumsum(restful)])
    ok = ((cs_hr[starts + WIN] - cs_hr[starts]) > WIN // 2) & \
         ((cs_rest[starts + WIN] - cs_rest[starts + WIN - N_FUTURE]) > N_FUTURE // 2)
    starts = starts[ok]
    rng = np.random.default_rng(int(now) // 86400)
    if len(starts) > self.train_windows:
      starts = np.sort(rng.choice(starts, size=self.train_windows, replace=False))
    self._apply(None)
    t0 = time.time()
    Xw, Mw, _ = self.core.make_windows(xs, WIN, 1, starts)
    tr = self.core.train_impute(self.model, Xw, Mw, self.targets, n_future=N_FUTURE, mode="prompt",
                                epochs=self.epochs, batch=self.batch, log=log.info)
    del Xw, Mw
    # Robust residual scale on the training span (stride = SCORE): z = (r − median) / (1.4826·MAD).
    r = self._residuals(xs, np.arange(WIN, len(xs) + 1, SCORE))
    med = np.nanmedian(r, axis=0)
    mad = 1.4826 * np.nanmedian(np.abs(r - med), axis=0)
    med = np.where(np.isfinite(med), med, 0.0).astype(np.float32)
    mad = np.where(np.isfinite(mad) & (mad > 1e-3), mad, 1.0).astype(np.float32)
    ds = self.core.DATASET
    user = {
      "prompt": self.model.prompt_tokens[ds].detach().clone(),
      "mask": self.model.mask_tokens[ds].detach().clone(),
      "mu": self.torch.from_numpy(mu), "sd": self.torch.from_numpy(sd),
      "res_med": self.torch.from_numpy(med), "res_mad": self.torch.from_numpy(mad),
      "meta": {"trained_at": float(now), "span_hours": self._usable_span_hours(frame),
               "n_windows": int(len(starts)), "train_s": round(time.time() - t0, 1),
               "loss": [round(float(x), 4) for x in tr["loss_hist"]], "version": self.version},
    }
    tmp = self._path(state) + ".tmp"
    self.torch.save(user, tmp)
    os.replace(tmp, self._path(state))
    # The score distribution changed with the prompt: this model's calibration restarts on the new prompt.
    for f in glob.glob(os.path.join(state.dir, f"ref_{self.name}_*.npy")) + \
             glob.glob(os.path.join(state.dir, f"refmeta_{self.name}_*.json")):
      os.remove(f)
    self.last_train = user["meta"]
    log.info("units prompt trained: %s", json.dumps(user["meta"]))
    return user

  # ---- scoring ---------------------------------------------------------------------------------------------------
  def _residuals(self, xs: np.ndarray, ends: np.ndarray, batch: int = 64) -> np.ndarray:
    """Signed residual (obs − reconstruction) for [e − SCORE, e) of each end index e; (len(ends)·SCORE, U)."""
    torch = self.torch
    U = len(self.targets)
    out = np.full((len(ends), SCORE, U), np.nan, dtype=np.float32)
    with torch.inference_mode():
      for b in range(0, len(ends), batch):
        ee = ends[b:b + batch]
        Xf, M, _ = self.core.make_windows(xs, WIN, 1, ee - WIN)
        keep = self.core.future_keep(len(ee), WIN, self.n_vars, N_FUTURE, self.targets)
        rec = self.core.impute_forward(self.model, torch.from_numpy(Xf), keep).numpy()
        r = (Xf - rec)[:, WIN - SCORE:, :U]
        out[b:b + len(ee)] = np.where(M[:, WIN - SCORE:, :U], r, np.nan)
    return out.reshape(-1, U)

  def generation(self, state) -> str:
    """Changes when this user's prompt is (re-)trained; the service then re-runs its calibration backfill."""
    user = self._prepared[1] if getattr(self, "_prepared", (None,))[0] == state.dir else self._load_user(state)
    return "untrained" if user is None else f"{user['meta'].get('trained_at', 0):.0f}"

  def prepare(self, frame, state) -> None:
    """Load (or train) this user's prompt before the service decides what to score; a re-train clears this
    model's calibration references, so the service's thin-reference backfill must see that first."""
    now = time.time()
    user = self._load_user(state)
    if self._needs_training(user, frame, now):
      user = self._train(frame, state, now)
    self._prepared = (state.dir, user)

  def score(self, frame, windows, state=None) -> list[tuple]:
    if not windows or state is None:
      return []
    if getattr(self, "_prepared", (None,))[0] != state.dir:
      self.prepare(frame, state)
    user = self._prepared[1]
    if user is None:
      return []                        # not enough history yet: this model abstains (stored as nothing)
    self._apply(user)
    xs = (self._matrix(frame) - user["mu"].numpy()) / user["sd"].numpy()
    index = {int(m): i for i, m in enumerate(frame.minutes)}
    keep, ends = [], []
    for w in windows:
      i = index.get(int(w.start))
      if i is None:
        continue
      e = i + SCORE
      if e - WIN < 0 or e > len(xs):
        continue
      if np.isfinite(xs[e - WIN:e - N_FUTURE, 0]).mean() < 0.5:   # visible HR context mostly missing
        continue
      keep.append(w)
      ends.append(e)
    if not keep:
      return []
    r = self._residuals(xs, np.asarray(ends))
    z = (r - user["res_med"].numpy()) / user["res_mad"].numpy()
    z = z.reshape(len(keep), SCORE, -1).transpose(0, 2, 1)         # (B, U, SCORE)
    return list(zip(keep, z))
