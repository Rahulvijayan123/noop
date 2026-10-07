"""UniTS (mims-harvard, NeurIPS 2024) on CPU: load released checkpoints, reconstruction
anomaly scoring, per-user prompt tuning / finetuning, empirical calibration.

Uses the unmodified model code from github.com/mims-harvard/UniTS @ 0e0281482864017cac8832b2651906ff5375a34e
(models/UniTS.py, MIT license) and the release-tag `ckpt` weights.

What the official anomaly-detection recipe is (exp/exp_sup.py + scripts/few_shot_anomaly_detection):
  * task_name='anomaly_detection' -> Model.anomaly_detection(): instance-normalise each variable over
    the window, patchify (16), prepend 10 dataset prompt tokens per variable, 3 UniTS blocks,
    reconstruct the whole window with the shared forecast_head. No masking, no AD-specific head.
  * training = MSE(reconstruction, input) on normal training windows (seq_len 96), either
    prompt tuning (only prompt/mask/cls tokens trainable) or full finetune.
  * score = per-timestep MSE averaged over variables; threshold = percentile of the
    train+test energy at `anomaly_ratio` (we replace that with a per-user empirical p-value).

Env: UNITS_SRC (checkout root), UNITS_CKPT (path to a .pth from the release).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

_HERE = Path(__file__).resolve().parent
UNITS_SRC = os.environ.get("UNITS_SRC", str(_HERE.parent / "vendor" / "units"))
UNITS_CKPT_DIR = os.environ.get("UNITS_CKPT_DIR", str(_HERE.parent / "weights" / "units-ckpt"))

_spec = importlib.util.spec_from_file_location("units_model", str(Path(UNITS_SRC, "models", "UniTS.py")))
units_model = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(units_model)

DATASET = "NARA"  # our new "dataset" key -> its own prompt tokens


def _safe_load(path: str) -> dict:
  """torch.load with weights_only=True plus the 2 non-tensor globals the pretrain ckpts pickle."""
  import argparse as _ap

  from numpy._core.multiarray import scalar

  safe = [(scalar, "numpy.core.multiarray.scalar"), _ap.Namespace, np.dtype,
          type(np.dtype("float64")), type(np.dtype("float32")), type(np.dtype("int64"))]
  with torch.serialization.safe_globals(safe):
    return torch.load(path, map_location="cpu", weights_only=True)


def load_units(
  ckpt: str = "units_x128_pretrain_checkpoint.pth",
  n_vars: int = 7,
  seq_len: int = 96,
  prompt_init: str = "mean",
  threads: int | None = None,
):
  """Builds UniTS with one new task ('NARA', anomaly_detection, n_vars) and loads pretrained weights.

  The released checkpoints only contain prompt tokens for their training datasets (ECL,
  ETTh1, ..., or MSL/PSM/SMAP/SMD/SWAT for the AD ones). A new dataset needs new prompt
  tokens: we initialise them from the mean of all pretrained prompt tokens (prompt_init='mean')
  or randomly (std .02, the repo default), then optionally prompt-tune them.
  """
  if threads:
    torch.set_num_threads(threads)
  # The DynamicLinearMlp fc1 is a Conv1d(k=3). On CPU builds without oneDNN (macOS arm64) torch
  # routes it to NNPACK, which is ~50x slower here than im2col+GEMM. Disable NNPACK.
  torch.backends.nnpack.set_flags(False)
  path = ckpt if os.path.isabs(ckpt) else str(Path(UNITS_CKPT_DIR, ckpt))
  raw = _safe_load(path)
  sd = raw["student"] if "student" in raw else raw
  sd = {k.removeprefix("module."): v for k, v in sd.items()}
  d_model = sd["patch_embeddings.value_embedding.weight"].shape[0]
  args = argparse.Namespace(
    d_model=d_model, n_heads=8, e_layers=3, patch_len=16, stride=16, prompt_num=10, dropout=0.0,
  )
  cfg = [(f"{DATASET}_AD", {"task_name": "anomaly_detection", "dataset": DATASET, "enc_in": n_vars,
                            "seq_len": seq_len, "label_len": 0, "pred_len": 0})]
  model = units_model.Model(args, cfg)
  # Drop tokens of datasets we do not use and the pretrain-only head.
  keep = {k: v for k, v in sd.items()
          if not k.startswith(("prompt_tokens.", "mask_tokens.", "cls_tokens.", "category_tokens.", "pretrain_head."))}
  msg = model.load_state_dict(keep, strict=False)
  assert all(k.startswith(("prompt_tokens.", "mask_tokens.")) for k in msg.missing_keys), msg.missing_keys
  assert not msg.unexpected_keys, msg.unexpected_keys
  with torch.no_grad():
    if prompt_init == "mean":
      pts = [v for k, v in sd.items() if k.startswith("prompt_tokens.")]
      mean_prompt = torch.cat([p.reshape(-1, p.shape[-2], p.shape[-1]) for p in pts]).mean(0)
      model.prompt_tokens[DATASET].copy_(mean_prompt.expand(1, n_vars, -1, -1))
      mts = [v for k, v in sd.items() if k.startswith("mask_tokens.")]
      if mts:
        model.mask_tokens[DATASET].copy_(torch.cat([m.reshape(-1, m.shape[-1]) for m in mts]).mean(0).expand(1, n_vars, 1, -1))
  model.eval()
  info = {
    "ckpt": os.path.basename(path), "d_model": d_model,
    "params_total_loaded_model": sum(p.numel() for p in model.parameters()),
    "params_backbone_heads": sum(p.numel() for n, p in model.named_parameters()
                                 if not n.startswith(("prompt_tokens", "mask_tokens", "position_embedding"))),
    "params_prompt": model.prompt_tokens[DATASET].numel(),
  }
  return model, info


def reconstruct(model, x: torch.Tensor) -> torch.Tensor:
  """x: (B, L, V) standardized, NaN-free. Returns reconstruction (B, L, V)."""
  return model(x, None, None, None, task_id=0, task_name="anomaly_detection")


def fill_nan(x: np.ndarray) -> np.ndarray:
  """(L, V) -> linear interpolation per column, edges held, all-NaN column -> 0 (= user mean)."""
  x = x.copy()
  idx = np.arange(x.shape[0])
  for j in range(x.shape[1]):
    m = np.isfinite(x[:, j])
    if m.all():
      continue
    x[:, j] = np.interp(idx, idx[m], x[m, j]) if m.any() else 0.0
  return x


class Standardizer:
  """Per-user, per-channel StandardScaler (as in UniTS' AD loaders), NaN-aware."""

  def __init__(self, hist: np.ndarray):  # (L, V)
    self.mu = np.nanmean(hist, 0)
    self.sd = np.nanstd(hist, 0) + 1e-6

  def __call__(self, x):
    return (x - self.mu) / self.sd


def make_windows(xs: np.ndarray, win: int, stride: int, starts=None):
  """xs: (L, V) standardized with NaN. Returns (inputs filled, observed-mask) as (N, win, V)."""
  if starts is None:
    starts = np.arange(0, xs.shape[0] - win + 1, stride)
  X = np.stack([xs[s : s + win] for s in starts])
  M = np.isfinite(X)
  Xf = np.stack([fill_nan(w) for w in X]).astype(np.float32)
  return Xf, M, starts


def train(
  model,
  X: np.ndarray,
  M: np.ndarray,
  mode: str = "prompt",
  epochs: int = 5,
  lr: float | None = None,
  batch: int = 32,
  loss_vars: list[int] | None = None,
  seed: int = 0,
  log=print,
):
  """Self-supervised reconstruction training on normal windows (official AD objective,
  restricted to observed entries). mode='prompt' trains only prompt tokens (official
  `choose_training_parts(prompt_tune=True)`), mode='finetune' trains everything.
  """
  torch.manual_seed(seed)
  for n, p in model.named_parameters():
    if mode == "prompt":
      p.requires_grad = any(t in n for t in ("prompt_token", "mask_token", "cls_token", "category_token"))
    else:
      p.requires_grad = True
  params = [p for p in model.parameters() if p.requires_grad]
  lr = lr or (3e-3 if mode == "prompt" else 1e-4)
  opt = torch.optim.Adam(params, lr=lr, weight_decay=0.0)
  Xt, Mt = torch.from_numpy(X), torch.from_numpy(M)
  if loss_vars is not None:
    sel = torch.zeros(X.shape[-1], dtype=torch.bool)
    sel[loss_vars] = True
    Mt = Mt & sel
  n = len(Xt)
  g = torch.Generator().manual_seed(seed)
  model.train()
  t0 = time.perf_counter()
  hist = []
  for ep in range(epochs):
    perm = torch.randperm(n, generator=g)
    tot = 0.0
    for b in range(0, n, batch):
      idx = perm[b : b + batch]
      out = reconstruct(model, Xt[idx])
      m = Mt[idx]
      loss = ((out - Xt[idx]) ** 2)[m].mean()
      opt.zero_grad()
      loss.backward()
      torch.nn.utils.clip_grad_norm_(params, 100.0)
      opt.step()
      tot += loss.item() * len(idx)
    for pg in opt.param_groups:  # halve per epoch (official 'finetune_anl'/'prompt_tuning' schedules)
      pg["lr"] *= 0.5
    hist.append(tot / n)
    log(f"  [{mode}] epoch {ep+1}/{epochs} loss {tot/n:.4f} ({time.perf_counter()-t0:.1f}s)")
  model.eval()
  for p in model.parameters():
    p.requires_grad = False
  return {"train_s": time.perf_counter() - t0, "loss_hist": hist}


@torch.inference_mode()
def minute_errors(model, xs: np.ndarray, win: int = 96, stride: int = 48, batch: int = 256) -> np.ndarray:
  """Per-minute, per-variable squared reconstruction error over a long standardized series
  (L, V), averaged over overlapping windows. NaN where the input was missing."""
  L, V = xs.shape
  starts = np.arange(0, L - win + 1, stride)
  if starts[-1] != L - win:
    starts = np.append(starts, L - win)
  acc = np.zeros((L, V))
  cnt = np.zeros((L, 1))
  for b in range(0, len(starts), batch):
    ss = starts[b : b + batch]
    Xf, M, _ = make_windows(xs, win, stride, ss)
    out = reconstruct(model, torch.from_numpy(Xf)).numpy()
    e = np.where(M, (out - Xf) ** 2, np.nan)
    for k, s in enumerate(ss):
      acc[s : s + win] += np.nan_to_num(e[k])
      cnt[s : s + win] += 1
  err = acc / np.maximum(cnt, 1)
  err[~np.isfinite(xs)] = np.nan
  return err


# ---------------------------------------------------------------------------
# Conditional ("forecast-style") reconstruction through UniTS' own imputation path.
# The official AD path reconstructs an un-masked, per-window instance-normalised input, so a
# level shift that fills the window is normalised away and an (almost) identity mapping is
# learned. The imputation path accepts a per-(variable, patch) mask: we hide the *target*
# channels in the last `n_future` steps while the covariates (motion, sleep, ...) stay visible,
# so the model must predict physiology from its recent past + the observed covariates.
# ---------------------------------------------------------------------------


def impute_forward(model, x: torch.Tensor, keep: torch.Tensor) -> torch.Tensor:
  """x: (B, L, V) filled; keep: (B, L, V) 1=visible, 0=hidden. Mirrors exp_sup.train_imputation."""
  xin = x.masked_fill(keep == 0, 0)
  return model(xin, None, None, None, task_id=0, mask=keep, task_name="imputation")


def future_keep(B, L, V, n_future, target_vars):
  keep = torch.ones(B, L, V)
  keep[:, L - n_future :, target_vars] = 0
  return keep


def train_impute(model, X, M, target_vars, n_future=32, mode="prompt", epochs=5, lr=None, batch=32,
                 seed=0, p_future=0.5, patch=16, log=print):
  """Self-supervised: hide target channels either in the last n_future steps (prob p_future) or
  in random 16-step patches (~40%); MSE on hidden & observed target entries."""
  torch.manual_seed(seed)
  for n, p in model.named_parameters():
    p.requires_grad = (mode != "prompt") or any(t in n for t in ("prompt_token", "mask_token"))
  params = [p for p in model.parameters() if p.requires_grad]
  opt = torch.optim.Adam(params, lr=lr or (3e-3 if mode == "prompt" else 1e-4))
  Xt, Mt = torch.from_numpy(X), torch.from_numpy(M)
  N, L, V = Xt.shape
  g = torch.Generator().manual_seed(seed)
  model.train()
  t0 = time.perf_counter()
  hist = []
  for ep in range(epochs):
    perm = torch.randperm(N, generator=g)
    tot = 0.0
    for b in range(0, N, batch):
      idx = perm[b : b + batch]
      xb, mb = Xt[idx], Mt[idx]
      B = len(idx)
      keep = future_keep(B, L, V, n_future, target_vars)
      rnd = torch.rand(B, generator=g) > p_future
      if rnd.any():
        pm = torch.rand(int(rnd.sum()), L // patch, generator=g) < 0.4
        pm[pm.all(1), 0] = False  # tokenize() divides by the visible count: keep >= 1 patch visible
        pm = pm.repeat_interleave(patch, dim=1)
        k2 = torch.ones(int(rnd.sum()), L, V)
        k2[:, :, target_vars] = (~pm).float().unsqueeze(-1)
        keep[rnd] = k2
      out = impute_forward(model, xb, keep)
      w = (keep == 0) & mb
      if not w.any():
        continue
      loss = ((out - xb) ** 2)[w].mean()
      opt.zero_grad()
      loss.backward()
      torch.nn.utils.clip_grad_norm_(params, 100.0)
      opt.step()
      tot += loss.item() * B
    for pg in opt.param_groups:
      pg["lr"] *= 0.5
    hist.append(tot / N)
    log(f"  [impute-{mode}] epoch {ep+1}/{epochs} loss {tot/N:.4f} ({time.perf_counter()-t0:.1f}s)")
  model.eval()
  for p in model.parameters():
    p.requires_grad = False
  return {"train_s": time.perf_counter() - t0, "loss_hist": hist}


@torch.inference_mode()
def future_residuals(model, xs: np.ndarray, target_vars, win=96, n_future=32, batch=256, score_last=None) -> np.ndarray:
  """Signed residual (obs - pred) for every step of a long standardized series (L, V), each step
  predicted once as part of a hidden 'future' block (covariates visible). NaN where unobserved
  or not scored (first win - n_future steps).
  score_last: only keep the last `score_last` steps of each hidden block ("lagged" mode: the
  visible context ends n_future - score_last steps before the scored steps)."""
  L, V = xs.shape
  res = np.full((L, len(target_vars)), np.nan, dtype=np.float32)
  step = score_last or n_future
  starts = np.arange(0, L - win + 1, step)
  for b in range(0, len(starts), batch):
    ss = starts[b : b + batch]
    Xf, M, _ = make_windows(xs, win, step, ss)
    xb = torch.from_numpy(Xf)
    keep = future_keep(len(ss), win, V, n_future, target_vars)
    out = impute_forward(model, xb, keep).numpy()
    r = (Xf - out)[:, win - step :, target_vars]
    r = np.where(M[:, win - step :, target_vars], r, np.nan)
    for k, s in enumerate(ss):
      res[s + win - step : s + win] = r[k]
  return res
