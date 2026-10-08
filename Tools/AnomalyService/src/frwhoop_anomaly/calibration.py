"""Per-user empirical calibration of model window scores.

A raw model score has no fixed meaning across people, channels or contexts. Every window score is converted to an
upper-tail p-value against the SAME user's own history of usable, unflagged windows of the same context bucket:
body p = (1 + #{ref ≥ s}) / (1 + n); beyond the 95th percentile an exponential peaks-over-threshold tail so scores
past the largest historical value still get distinct p. The tail scale is the one-sided 95 % UPPER confidence bound of
the exponential mean (2k·β̂ / χ²₀.₀₅(2k), k exceedances): with a thin reference (k ≈ 5) the tail is fattened ~2.5×,
with a full one (k ≈ 70) ~1.2×, so an α = 1e-3 flag is not an extrapolation artefact of a few points.

Sustained shifts (SustainedCalibrator): the mean of the last k windows' channel scores, calibrated against rolling
k-window means of the same user's reference sequence.

Consecutive windows are dependent, so when the reference rows' window starts are known each channel's body and tail
use the effective sample size n·(1−ρ)/(1+ρ) (ρ = lag-1 correlation over exactly-adjacent windows): a dependent
reference gives honestly wider p-values instead of overconfident ones.

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


def lag1_n_eff(x: np.ndarray, starts: np.ndarray | None, step_s: int = 1800, rho_max: float = 0.95) -> float:
  """Effective sample size of a time-ordered score sequence: n·(1−ρ)/(1+ρ), ρ = lag-1 correlation over pairs that
  are exactly one window apart (non-contiguous pairs carry no information about it). n when unknown."""
  x = np.asarray(x, dtype=np.float64)
  n = int(np.isfinite(x).sum())
  if starts is None or n < 10:
    return float(n)
  t = np.asarray(starts, dtype=np.float64)
  ok = np.isfinite(x[:-1]) & np.isfinite(x[1:]) & (np.abs(np.diff(t) - step_s) < 1)
  if ok.sum() < 8:
    return float(n)
  a, b = x[:-1][ok], x[1:][ok]
  sa, sb = a.std(), b.std()
  rho = float(np.mean((a - a.mean()) * (b - b.mean())) / (sa * sb)) if sa > 0 and sb > 0 else 0.0
  rho = min(max(rho, 0.0), rho_max)
  return max(2.0, n * (1 - rho) / (1 + rho))


class EmpiricalCalibrator:
  def __init__(self, reference: np.ndarray, tail_q: float = 0.95, conservative: bool = True,
               n_eff: float | None = None):
    r = np.asarray(reference, dtype=np.float64)
    self.ref = np.sort(r[np.isfinite(r)])
    n = len(self.ref)
    # Dependent reference rows (consecutive windows): body and tail uncertainty use the effective sample size.
    self.n_eff = float(n) if n_eff is None else float(min(max(n_eff, 1.0), n))
    self.tail_q = tail_q
    self.u: float | None = None
    self.beta: float | None = None
    if n >= 20:
      self.u = float(np.quantile(self.ref, tail_q))
      exc = self.ref[self.ref > self.u] - self.u
      if len(exc) and exc.mean() > 0:
        self.beta = float(exc.mean())
        if conservative:
          k = max(1.0, len(exc) * self.n_eff / n)
          self.beta *= 2 * k / _chi2_lower(2 * k, 1 - TAIL_CONFIDENCE)

  def pvalue(self, s: np.ndarray) -> np.ndarray:
    s = np.asarray(s, dtype=np.float64)
    n = len(self.ref)
    if n == 0:
      return np.ones_like(s)
    ge = n - np.searchsorted(self.ref, s, side="left")
    p = (1.0 + ge * self.n_eff / n) / (1.0 + self.n_eff)
    if self.beta is not None and self.u is not None:
      with np.errstate(over="ignore", invalid="ignore"):
        pt = (1 - self.tail_q) * np.exp(-(s - self.u) / self.beta)
      p = np.where(np.isfinite(s) & (s > self.u), np.minimum(p, pt), p)
    return np.where(np.isnan(s), 1.0, p)


class MultiChannel:
  """ref: (n_ref, U) per-channel window scores. pvalue(S: (N, U)) -> (combined p (N,), per-channel p (N, U))."""

  def __init__(self, ref: np.ndarray, starts: np.ndarray | None = None, step_s: int = 1800):
    self.ref = np.asarray(ref, dtype=np.float64)
    self.n = self.ref.shape[0] if self.ref.ndim == 2 else 0
    u = self.ref.shape[1] if self.ref.ndim == 2 else 0
    self.channel = [EmpiricalCalibrator(self.ref[:, j], n_eff=lag1_n_eff(self.ref[:, j], starts, step_s))
                    for j in range(u)]

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


class SustainedCalibrator(MultiChannel):
  """Calibrates the k-window mean of each channel's directional score against the same statistic over the user's
  own reference SEQUENCE (rows are appended in time order): rolling k-row means, so the dependence between
  consecutive windows is in the reference distribution itself and no independence or AR model is assumed. Channels
  are combined by Bonferroni as for single windows."""

  def __init__(self, ref: np.ndarray, starts: np.ndarray, k: int, window_s: int = 1800):
    ref = np.asarray(ref, dtype=np.float64)
    starts = np.asarray(starts, dtype=np.float64)
    if ref.ndim == 2 and len(ref) >= k and len(starts) == len(ref):
      fin = np.isfinite(ref)
      csum = np.concatenate([np.zeros((1, ref.shape[1])), np.cumsum(np.where(fin, ref, 0.0), axis=0)])
      ccnt = np.concatenate([np.zeros((1, ref.shape[1])), np.cumsum(fin, axis=0)])
      n = ccnt[k:] - ccnt[:-k]
      roll = np.where(n > 0, (csum[k:] - csum[:-k]) / np.maximum(n, 1), np.nan)
      # Only spans as contiguous as the live statistic's (k windows within k·W): rows far apart in time are less
      # correlated, so mixing them in would make the reference too narrow (anti-conservative).
      span = starts[k - 1:] - starts[:len(starts) - k + 1]
      keep = np.isfinite(span) & (span <= k * window_s)
      roll, roll_t = roll[keep], starts[:len(starts) - k + 1][keep]
    else:
      roll, roll_t = np.zeros((0, ref.shape[1] if ref.ndim == 2 else 0)), np.zeros(0)
    # Overlapping k-window means are strongly dependent: n_eff from their own lag-1 correlation.
    super().__init__(roll, roll_t, window_s)
