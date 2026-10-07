"""Numpy-only head, calibration and OOD math for ``HeadBundle.apply`` (INERTIA1.md §5).

No torch, sklearn or pandas: the serve process applies trained heads with these functions only. The
single non-numpy call is ``scipy.special.erf`` for the exact (erf) GELU, so an MLP head trained with
``torch.nn.GELU()`` (approximate="none") reproduces bit-closely here.

All math runs in float64; inputs may be any float dtype.

Conventions
-----------
* ``z = (emb - std.mu) / std.sigma`` (global standardisation, fit on train).
* linear head: ``logits = z @ W.T + b``; MLP head: ``LayerNorm(eps=1e-5, ln_g, ln_b) -> W1, b1 ->
  GELU(erf) -> W2, b2`` (LayerNorm uses the biased variance, as torch does).
* Softmax heads: calibration acts on the logits of *supported* classes only (unsupported classes are
  -inf, i.e. they never receive mass): ``temperature`` z/T; ``temp_bias`` z/T + b; ``vector`` w*z + b;
  then softmax over the supported classes.
* Multi-label event heads (``transition``): ``temperature_per_event`` — each supported event e gets
  ``sigmoid(z_e / T_e)`` independently (values need not sum to 1).
* OOD scores (larger = more novel): see the individual functions.
"""

from __future__ import annotations

import math
from typing import Optional

import numpy as np
from scipy.special import erf

LAYER_NORM_EPS = 1e-5
SOFTMAX_CALIBRATION_METHODS = ("temperature", "temp_bias", "vector")
MULTILABEL_CALIBRATION_METHODS = ("temperature_per_event",)
CALIBRATION_METHODS = SOFTMAX_CALIBRATION_METHODS + MULTILABEL_CALIBRATION_METHODS
OOD_METHODS = ("maha_min", "maha_global", "knn", "energy")


def standardize(emb: np.ndarray, mu: np.ndarray, sigma: np.ndarray) -> np.ndarray:
    return (np.asarray(emb, dtype=np.float64) - np.asarray(mu, dtype=np.float64)) \
        / np.asarray(sigma, dtype=np.float64)


def layer_norm(x: np.ndarray, gamma: np.ndarray, beta: np.ndarray, eps: float = LAYER_NORM_EPS) -> np.ndarray:
    mean = x.mean(axis=-1, keepdims=True)
    var = ((x - mean) ** 2).mean(axis=-1, keepdims=True)
    return (x - mean) / np.sqrt(var + eps) * np.asarray(gamma, np.float64) + np.asarray(beta, np.float64)


def gelu_exact(x: np.ndarray) -> np.ndarray:
    """GELU with the exact Gaussian CDF (torch.nn.GELU(approximate='none'))."""
    return 0.5 * x * (1.0 + erf(x / math.sqrt(2.0)))


def linear_logits(z: np.ndarray, W: np.ndarray, b: np.ndarray) -> np.ndarray:
    return z @ np.asarray(W, np.float64).T + np.asarray(b, np.float64)


def mlp_logits(z: np.ndarray, ln_g: np.ndarray, ln_b: np.ndarray, W1: np.ndarray, b1: np.ndarray,
               W2: np.ndarray, b2: np.ndarray) -> np.ndarray:
    h = layer_norm(z, ln_g, ln_b)
    h = gelu_exact(linear_logits(h, W1, b1))
    return linear_logits(h, W2, b2)


def softmax(x: np.ndarray, axis: int = -1) -> np.ndarray:
    m = np.max(x, axis=axis, keepdims=True)
    e = np.exp(x - m)
    return e / e.sum(axis=axis, keepdims=True)


def logsumexp(x: np.ndarray, axis: int = -1) -> np.ndarray:
    m = np.max(x, axis=axis, keepdims=True)
    return (m + np.log(np.exp(x - m).sum(axis=axis, keepdims=True))).squeeze(axis)


def sigmoid(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, np.float64)
    out = np.empty_like(x)
    pos = x >= 0
    out[pos] = 1.0 / (1.0 + np.exp(-x[pos]))
    ex = np.exp(x[~pos])
    out[~pos] = ex / (1.0 + ex)
    return out


def calibrate(logits: np.ndarray, method: str, T: Optional[float] = None,
              weight: Optional[np.ndarray] = None, bias: Optional[np.ndarray] = None) -> np.ndarray:
    """Calibrated logits for the supported-class columns ``logits [B, Ks]``.

    ``T`` is a scalar for temperature/temp_bias and a ``[Ks]`` vector for temperature_per_event."""
    if method == "temperature_per_event":
        return logits / np.asarray(T, np.float64)
    if method == "temperature":
        return logits / float(T)
    if method == "temp_bias":
        return logits / float(T) + np.asarray(bias, np.float64)
    if method == "vector":
        return logits * np.asarray(weight, np.float64) + np.asarray(bias, np.float64)
    raise ValueError(f"unknown calibration method {method!r}")


def _quad_form(diff: np.ndarray, precision: np.ndarray) -> np.ndarray:
    """sqrt(max(0, d^T P d)) over the last axis of ``diff``."""
    q = np.einsum("...i,ij,...j->...", diff, np.asarray(precision, np.float64), diff)
    return np.sqrt(np.maximum(q, 0.0))


def ood_maha_min(z: np.ndarray, class_means: np.ndarray, precision: np.ndarray) -> np.ndarray:
    """min over classes c of sqrt((z - mu_c)^T P (z - mu_c)) — tied-covariance class-conditional Mahalanobis."""
    diff = z[:, None, :] - np.asarray(class_means, np.float64)[None, :, :]
    return _quad_form(diff, precision).min(axis=1)


def ood_maha_global(z: np.ndarray, mean: np.ndarray, precision: np.ndarray) -> np.ndarray:
    """sqrt((z - m)^T P (z - m)) against one global Gaussian."""
    return _quad_form(z - np.asarray(mean, np.float64)[None, :], precision)


def ood_knn(z: np.ndarray, reference: np.ndarray, k: int, chunk: int = 256) -> np.ndarray:
    """k-th smallest Euclidean distance between L2-normalised ``z`` and the reference set.

    ``reference`` is stored float16 (already L2-normalised at fit time); both sides are float32 here, as
    the contract pins. A zero vector stays zero (it cannot be normalised)."""
    ref = np.asarray(reference, dtype=np.float32)
    r2 = np.einsum("ij,ij->i", ref, ref)
    zf = np.asarray(z, dtype=np.float32)
    norms = np.linalg.norm(zf, axis=1, keepdims=True)
    u = np.where(norms > 0, zf / np.where(norms > 0, norms, 1), 0).astype(np.float32)
    out = np.empty(u.shape[0], dtype=np.float32)
    for i in range(0, u.shape[0], chunk):
        ub = u[i:i + chunk]
        # errstate: macOS Accelerate raises spurious FP flags on float32 matmul (values are exact);
        # nonfinite results are still caught by the caller's finiteness mask.
        with np.errstate(all="ignore"):
            d2 = np.einsum("ij,ij->i", ub, ub)[:, None] + r2[None, :] - 2.0 * (ub @ ref.T)
        d = np.sqrt(np.maximum(d2, 0.0, dtype=np.float32))
        out[i:i + chunk] = np.partition(d, k - 1, axis=1)[:, k - 1]
    return out.astype(np.float64)


def ood_energy(raw_logits_supported: np.ndarray) -> np.ndarray:
    """Energy score: -logsumexp of a head's raw (uncalibrated) supported-class logits."""
    return -logsumexp(np.asarray(raw_logits_supported, np.float64), axis=-1)
