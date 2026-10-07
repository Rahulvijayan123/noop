"""Subject-cluster bootstrap (ported from Agent E): resample SUBJECTS with replacement (within strata).

``metric(idx)`` is evaluated on row indices of a subject resample; for paired comparisons pass a metric
that computes the DIFFERENCE on the same rows. Degenerate resamples (metric NaN) are dropped and counted.
With < 10 subjects the percentile CI under-covers and the result says so.
"""

from __future__ import annotations

from typing import Callable, Dict, Optional

import numpy as np


def cluster_bootstrap(metric: Callable[[np.ndarray], float], subjects: np.ndarray, strata: Optional[np.ndarray] = None,
                      n_boot: int = 1000, seed: int = 0, alpha: float = 0.05) -> Dict:
    rng = np.random.default_rng(seed)
    subjects = np.asarray(subjects).astype(str)
    strata = np.zeros(len(subjects), int) if strata is None else np.asarray(strata).astype(str)
    groups = {}
    for st in np.unique(strata):
        su = np.unique(subjects[strata == st])
        groups[st] = [np.flatnonzero((subjects == s) & (strata == st)) for s in su]
    point = float(metric(np.arange(len(subjects)))) if len(subjects) else float("nan")
    vals = []
    for _ in range(n_boot):
        parts = [g[i] for g in groups.values() for i in rng.integers(0, len(g), len(g))]
        idx = np.concatenate(parts) if parts else np.zeros(0, int)
        vals.append(float(metric(idx)) if len(idx) else float("nan"))
    vals = np.asarray(vals, float)
    ok = np.isfinite(vals)
    n_subj = int(sum(len(g) for g in groups.values()))
    lo, hi = (np.quantile(vals[ok], [alpha / 2, 1 - alpha / 2]) if ok.any() else (np.nan, np.nan))
    return {"point": point, "ci_low": float(lo), "ci_high": float(hi), "n_boot": int(ok.sum()),
            "n_degenerate": int((~ok).sum()), "n_subjects": n_subj,
            "warning": "fewer than 10 subjects: percentile CI under-covers" if n_subj < 10 else None}


__all__ = ["cluster_bootstrap"]
