"""Per-user empirical calibration of model window scores.

A raw model score has no fixed meaning across people, channels or contexts. Every window score is converted to an
upper-tail p-value against the SAME user's own history of usable, unflagged windows of the same context bucket:
body p = (1 + #{ref ≥ s}) / (1 + n); beyond the 95th percentile an exponential peaks-over-threshold tail so scores
past the largest historical value still get distinct p. The tail scale is the one-sided 95 % UPPER confidence bound of
the exponential mean (2k·β̂ / χ²₀.₀₅(2k), k exceedances): with a thin reference (k ≈ 5) the tail is fattened ~2.5×,
with a full one (k ≈ 70) ~1.2×, so an α = 1e-3 flag is not an extrapolation artefact of a few points.

Channels are combined by Bonferroni over the observed channels, p = min(1, U_obs · min p_j). It is valid under any
dependence between channels and needs no reference of its own. Measured under the null (40 references each,
tests + docs/BASELINE_WATCHDOG_V2.md §5): at α = 1e-3 the rate is ≤ 1× nominal for Gaussian and correlated
(ρ = 0.6, t5) channels at every reference size 96–1400, and 1–2× nominal for heavy-tailed t4 channels. An earlier
min-p re-calibration on the reference was 4–16× nominal with a 96-window reference and could never go below
1/(n+1) for an extreme window (it ranked −min p, a bounded statistic) — replaced.
"""

from __future__ import annotations

import math

import numpy as np

MIN_REFERENCE = 96          # ≈ 2 days of 30-minute windows in one context bucket before any candidate
TAIL_CONFIDENCE = 0.95


def _chi2_lower(dof: int, alpha: float) -> float:
  """Lower α-quantile of χ²(dof) (Wilson–Hilferty; within 1 % for dof ≥ 10)."""
  z = -_norm_upper(alpha)
  return max(1e-9, dof * (1 - 2 / (9 * dof) + z * math.sqrt(2 / (9 * dof))) ** 3)


def _norm_upper(alpha: float) -> float:
  """z with P(Z > z) = alpha (bisection on erfc; alpha in (0, 0.5))."""
  lo, hi = 0.0, 10.0
  for _ in range(80):
    mid = (lo + hi) / 2
    if 0.5 * math.erfc(mid / math.sqrt(2)) > alpha:
      lo = mid
    else:
      hi = mid
  return (lo + hi) / 2


class EmpiricalCalibrator:
  def __init__(self, reference: np.ndarray, tail_q: float = 0.95, conservative: bool = True):
    r = np.asarray(reference, dtype=np.float64)
    self.ref = np.sort(r[np.isfinite(r)])
    self.tail_q = tail_q
    self.u: float | None = None
    self.beta: float | None = None
    if len(self.ref) >= 20:
      self.u = float(np.quantile(self.ref, tail_q))
      exc = self.ref[self.ref > self.u] - self.u
      if len(exc) and exc.mean() > 0:
        self.beta = float(exc.mean())
        if conservative:
          k = len(exc)
          self.beta *= 2 * k / _chi2_lower(2 * k, 1 - TAIL_CONFIDENCE)

  def pvalue(self, s: np.ndarray) -> np.ndarray:
    s = np.asarray(s, dtype=np.float64)
    n = len(self.ref)
    if n == 0:
      return np.ones_like(s)
    ge = n - np.searchsorted(self.ref, s, side="left")
    p = (1.0 + ge) / (1.0 + n)
    if self.beta is not None and self.u is not None:
      with np.errstate(over="ignore", invalid="ignore"):
        pt = (1 - self.tail_q) * np.exp(-(s - self.u) / self.beta)
      p = np.where(np.isfinite(s) & (s > self.u), np.minimum(p, pt), p)
    return np.where(np.isnan(s), 1.0, p)


class MultiChannel:
  """ref: (n_ref, U) per-channel window scores. pvalue(S: (N, U)) -> (combined p (N,), per-channel p (N, U))."""

  def __init__(self, ref: np.ndarray):
    self.ref = np.asarray(ref, dtype=np.float64)
    self.n = self.ref.shape[0] if self.ref.ndim == 2 else 0
    u = self.ref.shape[1] if self.ref.ndim == 2 else 0
    self.channel = [EmpiricalCalibrator(self.ref[:, j]) for j in range(u)]

  @property
  def ready(self) -> bool:
    return self.n >= MIN_REFERENCE

  def pvalue(self, scores: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    scores = np.atleast_2d(np.asarray(scores, dtype=np.float64))
    if not self.channel:
      return np.ones(scores.shape[0]), np.ones_like(scores)
    observed = np.isfinite(scores) & np.array([len(c.ref) >= 20 for c in self.channel])[None, :]
    per = np.column_stack([c.pvalue(scores[:, j]) for j, c in enumerate(self.channel)])
    per = np.where(observed, per, 1.0)
    u_obs = np.maximum(observed.sum(axis=1), 1)
    combined = np.minimum(1.0, u_obs * per.min(axis=1))
    return combined, per
