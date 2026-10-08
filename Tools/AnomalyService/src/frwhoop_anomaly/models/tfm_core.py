"""TimesFM 3.0 (PyTorch, CPU) loader + forecast-residual anomaly scoring.

Reusable module: no repo-specific imports. Point TIMESFM_SRC at the pinned
google-research/timesfm checkout's `src` dir (or pip-install that commit) and
TIMESFM_WEIGHTS at a local snapshot of HF google/timesfm-3.0-pytorch.

Pinned versions (see NOTES.md):
  code    github.com/google-research/timesfm @ e51928e27119cb17bebc005be2696b75e0a9e688
  weights huggingface.co/google/timesfm-3.0-pytorch @ 43046b85ec22d584a13f8098c2ed39c889e129c2
          model.safetensors sha256 a7592b0a8432baee54483254e5647856911ce69e09d09a9bb65904b2d98f17da
"""

from __future__ import annotations

import dataclasses
import json
import math
import os
import sys
from pathlib import Path

import numpy as np
import torch

_HERE = Path(__file__).resolve().parent
TIMESFM_SRC = os.environ.get("TIMESFM_SRC", str(_HERE.parent / "vendor" / "timesfm" / "src"))
TIMESFM_WEIGHTS = os.environ.get(
  "TIMESFM_WEIGHTS", str(_HERE.parent / "weights" / "timesfm-3.0-pytorch")
)
if TIMESFM_SRC not in sys.path:
  sys.path.insert(0, TIMESFM_SRC)

from timesfm3.torch import timesfm3_forecaster as tfm_fc  # noqa: E402
from timesfm3.torch import model as tfm_model  # noqa: E402

QUANTILES = np.array([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9], dtype=np.float32)
# For a Gaussian, q90 - q10 = 2 * 1.2816 * sigma.
_Q10_Q90_TO_SIGMA = 1.0 / (2 * 1.2815516)


def load_timesfm(
  weights_dir: str = TIMESFM_WEIGHTS,
  threads: int | None = None,
  low_mem: bool = True,
  per_core_batch_size: int = 8,
  int8_dynamic: bool = False,
) -> tfm_fc.TimesFM3Forecaster:
  """Loads TimesFM 3.0 on CPU.

  low_mem=True builds the module on the meta device and assigns tensors that
  safetensors memory-maps from disk, so the 1.32 GB fp32 checkpoint is never held
  twice (the official `TimesFM3Torch.from_pretrained` path materialises a random-init
  model *and* the state dict, peaking at ~2x weights). Numerically identical.
  """
  if threads:
    torch.set_num_threads(threads)
  if not low_mem:
    fc = tfm_fc.TimesFM3Forecaster(
      tfm_fc.ModelConfig(
        checkpoint_path=weights_dir,
        device="cpu",
        local_files_only=True,
        per_core_batch_size=per_core_batch_size,
      )
    )
  else:
    from safetensors.torch import load_file

    cfg = json.loads(Path(weights_dir, "config.json").read_text())
    with torch.device("meta"):
      m = tfm_model.TimesFM3Torch(**cfg)
    sd = load_file(str(Path(weights_dir, "model.safetensors")), device="cpu")
    m.load_state_dict(sd, strict=True, assign=True)
    del sd
    # Non-persistent buffers (RoPE timescales) are not in the checkpoint and were
    # created on the meta device: rebuild them on CPU exactly as __init__ does.
    from timesfm3.torch import transformer as tfm_tr

    for mod in m.modules():
      if isinstance(mod, tfm_tr.RotaryPositionalEmbedding):
        half = mod.embedding_dims // 2
        frac = 2.0 * torch.arange(half, dtype=torch.float32) / mod.embedding_dims
        mod.timescale = mod.min_timescale * (mod.max_timescale / mod.min_timescale) ** frac
    for name, b in m.named_buffers():
      assert b.device.type != "meta", name
    for name, p in m.named_parameters():
      assert p.device.type != "meta", name
    m.eval()
    fc = tfm_fc.TimesFM3Forecaster.__new__(tfm_fc.TimesFM3Forecaster)
    fc.device = torch.device("cpu")
    fc.model = m
    fc.config = tfm_fc.ModelConfig(
      checkpoint_path=weights_dir,
      device="cpu",
      per_core_batch_size=per_core_batch_size,
      input_patch_length=m.input_patch_len,
      output_patch_length=m.output_patch_len,
      quantiles=list(m.quantiles),
      median_quantile_index=len(m.quantiles) // 2,
      residual_block_config=m.residual_block_config,
      transformer_config=m.transformer_config,
      use_variate_attention=m.use_variate_attention,
      value_clip=m.value_clip,
      use_stitching=m.use_stitching,
      use_linear_detrending=m.use_linear_detrending,
      linear_detrending_threshold=m.linear_detrending_threshold,
      use_iterative_cpm_revin=m.use_iterative_cpm_revin,
      use_frozen_running_stats=m.use_frozen_running_stats,
      input_transform=m.input_transform,
    )
  if int8_dynamic:
    engines = torch.backends.quantized.supported_engines
    for eng in ("x86", "fbgemm", "qnnpack"):
      if eng in engines:
        torch.backends.quantized.engine = eng
        break
    fc.model = torch.ao.quantization.quantize_dynamic(
      fc.model, {torch.nn.Linear}, dtype=torch.qint8, inplace=True
    )
  return fc


def count_params(fc) -> int:
  return sum(p.numel() for p in fc.model.parameters())


# ---------------------------------------------------------------------------
# Masked decode: the public predict_batch() linearly interpolates NaNs. The
# model's decode() accepts real per-point masks (target_mask, past_only_mask,
# past_future_mask); this helper exposes them so missing SpO2 / off-wrist minutes
# are *masked* instead of invented.
# ---------------------------------------------------------------------------


def _fill_for_model(x: np.ndarray, missing: str = "interp") -> tuple[np.ndarray, np.ndarray]:
  """missing='interp': NaN -> linear interpolation, no mask (== official predict_batch behaviour,
  and the better-calibrated option, see NOTES). missing='mask': NaN -> row mean + mask=True."""
  x = np.asarray(x, dtype=np.float32)
  if missing == "interp":
    return tfm_fc.linear_interpolation(x.copy()), np.zeros(x.shape, dtype=bool)
  if missing.startswith("hybrid"):
    # interpolate short gaps (<= max_gap minutes), mask long gaps and leading gaps
    max_gap = int(missing.removeprefix("hybrid") or 15)
    x2 = np.atleast_2d(x)
    mask = np.zeros(x2.shape, dtype=bool)
    for r in range(x2.shape[0]):
      nan = ~np.isfinite(x2[r])
      if not nan.any():
        continue
      d = np.diff(np.concatenate([[0], nan.astype(np.int8), [0]]))
      for a, b in zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)):
        if b - a > max_gap or a == 0:
          mask[r, a:b] = True
    filled = tfm_fc.linear_interpolation(x2.copy())
    return filled.reshape(x.shape), mask.reshape(x.shape)
  mask = ~np.isfinite(x)
  if mask.any():
    x = x.copy()
    for r in range(x.shape[0]):
      if mask[r].all():
        x[r] = 0.0
      elif mask[r].any():
        x[r, mask[r]] = np.nanmean(x[r])
  return x, mask


@torch.inference_mode()
def forecast_masked(
  fc,
  targets: list[np.ndarray],
  horizon: int,
  past_future_covariates: list[np.ndarray] | None = None,
  past_only_covariates: list[np.ndarray] | None = None,
  batch_size: int = 8,
  missing: str = "interp",
) -> np.ndarray:
  """Batched decode of a list of multivariate windows (the official forecaster semantics, without
  symmetric averaging / make_positive).

  missing='interp' (default) reproduces predict_batch's NaN handling (linear interpolation).
  missing='mask' passes per-point masks to decode() instead; measured on sparse channels
  (SpO2 ~70% missing) this gives 3-4x wider, over-covering intervals, so it is NOT the default.

  targets: list of (U, C) arrays (U target variates, C context minutes, NaN = missing).
  past_future_covariates: list of (W, C + horizon) arrays (known through the horizon).
  past_only_covariates: list of (V, C) arrays.
  Returns quantiles array (B, U, horizon, 9), sorted along the quantile axis.
  All items in the list must share C (pad/trim upstream).
  """
  outs = []
  m = fc.model
  for s in range(0, len(targets), batch_size):
    tg = targets[s : s + batch_size]
    vals, masks = zip(*[_fill_for_model(t, missing) for t in tg])
    tgt = torch.from_numpy(np.stack(vals))
    tmask = torch.from_numpy(np.stack(masks))
    kw = {}
    if past_future_covariates is not None:
      pf = past_future_covariates[s : s + batch_size]
      pv, pm = zip(*[_fill_for_model(p, missing) for p in pf])
      kw["past_future_covariates"] = torch.from_numpy(np.stack(pv))
      kw["past_future_mask"] = torch.from_numpy(np.stack(pm))
    if past_only_covariates is not None:
      po = past_only_covariates[s : s + batch_size]
      ov, om = zip(*[_fill_for_model(p, missing) for p in po])
      kw["past_only_covariates"] = torch.from_numpy(np.stack(ov))
      kw["past_only_mask"] = torch.from_numpy(np.stack(om))
    out = m.decode(target=tgt, horizon=horizon, target_mask=tmask, **kw)
    outs.append(out[:, : tgt.shape[1]].float().cpu().numpy())
  q = np.concatenate(outs, axis=0)
  return np.sort(q, axis=-1)


# ---------------------------------------------------------------------------
# Forecast residual -> anomaly score -> calibrated p-value
# ---------------------------------------------------------------------------


def quantile_z(obs: np.ndarray, q: np.ndarray, sigma_floor: np.ndarray | float = 1e-3) -> np.ndarray:
  """Signed standardized residual of observation vs predictive quantiles.

  obs: (..., H) observed horizon values (NaN allowed)
  q:   (..., H, 9) predicted deciles
  z = (obs - q50) / sigma_hat, sigma_hat = (q90 - q10)/2.563, floored.
  """
  q50 = q[..., 4]
  sig = (q[..., 8] - q[..., 0]) * _Q10_Q90_TO_SIGMA
  sig = np.maximum(sig, sigma_floor)
  return (obs - q50) / sig


def window_score(z: np.ndarray, sign: np.ndarray | None = None) -> np.ndarray:
  """Aggregates per-point z (..., U, H) into one score per window.

  sign: optional (U,) array of +1/-1/0 selecting the clinically relevant
  direction per channel (e.g. HR +1, HRV -1, SpO2 -1, temp +1, resp +1); 0 = two-sided.
  Score = max over channels of the mean directional z over the horizon (NaN-safe).
  A sustained shift raises the mean; a single spike barely moves it.
  """
  if sign is not None:
    s = np.asarray(sign, dtype=np.float32).reshape((1,) * (z.ndim - 2) + (-1, 1))
    zz = np.where(s == 0, np.abs(z), z * s)
  else:
    zz = np.abs(z)
  per_ch = np.nanmean(zz, axis=-1)
  per_ch = np.where(np.isfinite(per_ch), per_ch, -np.inf)
  return per_ch.max(axis=-1)


class EmpiricalCalibrator:
  """Maps raw window scores to an upper-tail p-value using the user's own history.

  Body: p = (1 + #{ref >= s}) / (1 + n). Tail (s above the 95th percentile u of the reference):
  exponential peaks-over-threshold fit, p = 0.05 * exp(-(s - u) / beta) with beta = mean excess
  over u, so scores beyond the largest historical value still get distinct, smaller p-values
  instead of all tying at 1/(n+1). Store the sorted reference per user (optionally per context
  bucket) and refresh it daily.
  """

  def __init__(self, reference_scores: np.ndarray, tail_q: float = 0.95):
    r = np.asarray(reference_scores, dtype=np.float64)
    self.ref = np.sort(r[np.isfinite(r)])
    self.tail_q = tail_q
    if len(self.ref) >= 20:
      self.u = float(np.quantile(self.ref, tail_q))
      exc = self.ref[self.ref > self.u] - self.u
      self.beta = float(exc.mean()) if len(exc) and exc.mean() > 0 else None
    else:
      self.u, self.beta = None, None

  def pvalue(self, s: np.ndarray) -> np.ndarray:
    s = np.asarray(s, dtype=np.float64)
    n = len(self.ref)
    ge = n - np.searchsorted(self.ref, s, side="left")
    p = (1.0 + ge) / (1.0 + n)
    if self.beta is not None:
      with np.errstate(over="ignore", invalid="ignore"):
        pt = (1 - self.tail_q) * np.exp(-(s - self.u) / self.beta)
      p = np.where(np.isfinite(s) & (s > self.u), np.minimum(p, pt), p)
    return np.where(np.isnan(s), 1.0, p)


def channel_scores(z: np.ndarray, sign: np.ndarray) -> np.ndarray:
  """(N, U, H) z -> (N, U) mean directional z per channel over observed horizon minutes
  (NaN where a channel has no observation in the window). sign 0 = two-sided |z|."""
  s = np.asarray(sign, dtype=np.float32)[None, :, None]
  zz = np.where(s == 0, np.abs(z), z * s)
  with np.errstate(all="ignore"):
    return np.nanmean(zz, axis=-1)


class MultiChannelCalibrator:
  """Per-user, per-channel empirical calibration combined by min-p, then re-calibrated.

  fit(ref): ref = (n_ref, U) per-channel window scores from the user's own recent history.
  pvalue(S): S = (N, U) -> (N,) p-values. Channel c gets p_c from its own reference
  distribution (a channel with no data in a window gets p_c = 1); the statistic min_c p_c is
  then converted to a p-value against the same statistic on the reference windows, which
  corrects for looking at U channels without assuming independence.
  Also returns per-channel p-values for explanation ("HR +3.1 sigma, p=0.002").
  """

  def __init__(self, ref: np.ndarray):
    ref = np.asarray(ref, dtype=np.float64)
    self.ch = [EmpiricalCalibrator(ref[:, c]) for c in range(ref.shape[1])]
    self.min_ref = EmpiricalCalibrator(-np.log(self._minp(ref)[0]))

  def _minp(self, S):
    P = np.ones(S.shape, dtype=np.float64)
    for c, cal in enumerate(self.ch):
      f = np.isfinite(S[:, c])
      P[f, c] = cal.pvalue(S[f, c])
    return P.min(axis=1), P

  def pvalue(self, S: np.ndarray, return_channels: bool = False):
    m, P = self._minp(np.asarray(S, dtype=np.float64))
    p = self.min_ref.pvalue(-np.log(m))
    return (p, P) if return_channels else p


def context_bucket(motion: np.ndarray, sleep: np.ndarray, active_thr: float = 0.25) -> np.ndarray:
  """Covariate-only context bucket per window (no labels needed): (N, H) motion occupancy and
  sleep bit over the scored window -> 0 asleep, 1 awake-rest, 2 active."""
  with np.errstate(all="ignore"):
    m = np.nanmean(motion, axis=-1)
    s = np.nanmean(sleep, axis=-1)
  return np.where(s >= 0.5, 0, np.where(m >= active_thr, 2, 1)).astype(np.int8)


class BucketedCalibrator:
  """MultiChannelCalibrator per context bucket (asleep / rest / active), so e.g. a hard workout is
  compared with the user's own past workouts, not with their resting windows. Falls back to the
  pooled calibrator when a bucket has fewer than `min_ref` reference windows."""

  def __init__(self, ref: np.ndarray, ref_bucket: np.ndarray, min_ref: int = 40):
    self.pooled = MultiChannelCalibrator(ref)
    self.cal = {}
    for b in np.unique(ref_bucket):
      sel = ref_bucket == b
      if sel.sum() >= min_ref:
        self.cal[int(b)] = MultiChannelCalibrator(ref[sel])

  def pvalue(self, S: np.ndarray, bucket: np.ndarray) -> np.ndarray:
    p = self.pooled.pvalue(S)
    for b, cal in self.cal.items():
      sel = bucket == b
      if sel.any():
        p[sel] = cal.pvalue(S[sel])
    return p
