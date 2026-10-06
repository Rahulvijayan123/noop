"""Binary gait-detection metrics with subject-cluster bootstrap CIs (validation only).

Point metrics are window-level; CIs resample SUBJECTS with replacement (within dataset strata for pooled sets)
from per-subject confusion counts (fast and exact for P / R / F1 / balanced accuracy), AUROC through
``inertia.bootstrap.cluster_bootstrap``. Fewer than 5 subjects or 50 windows of either class is marked
``small_sample`` (the CI is then not trustworthy either; percentile CIs under-cover below 10 subjects).
"""

from __future__ import annotations

from typing import Dict, Optional

import numpy as np

N_BOOT = 1000
N_BOOT_AUC = 300
SEED = 0
SMALL_SUBJECTS = 5
SMALL_WINDOWS = 50


def _prf(tp, fp, fn, tn) -> Dict[str, float]:
    tp, fp, fn, tn = (np.asarray(v, float) for v in (tp, fp, fn, tn))
    with np.errstate(divide="ignore", invalid="ignore"):
        prec = np.where(tp + fp > 0, tp / (tp + fp), np.nan)
        rec = np.where(tp + fn > 0, tp / (tp + fn), np.nan)
        spec = np.where(tn + fp > 0, tn / (tn + fp), np.nan)
        f1 = np.where(prec + rec > 0, 2 * prec * rec / (prec + rec), np.nan)
    return {"precision": prec, "recall": rec, "specificity": spec, "f1": f1, "balanced_accuracy": (rec + spec) / 2}


def counts_by_subject(pred: np.ndarray, y: np.ndarray, subjects: np.ndarray):
    uniq, si = np.unique(np.asarray(subjects).astype(str), return_inverse=True)
    S = len(uniq)
    c = np.zeros((S, 4))
    for k, m in enumerate((pred & y, pred & ~y, ~pred & y, ~pred & ~y)):
        c[:, k] = np.bincount(si, weights=m.astype(float), minlength=S)
    return uniq, c


def binary_report(p: np.ndarray, y: np.ndarray, subjects: np.ndarray, threshold: float,
                  strata: Optional[np.ndarray] = None, n_boot: int = N_BOOT, seed: int = SEED) -> Dict:
    p, y = np.asarray(p, float), np.asarray(y, bool)
    pred = p >= threshold
    uniq, c = counts_by_subject(pred, y, subjects)
    point = {k: float(v) for k, v in _prf(*c.sum(0)).items()}
    st = np.zeros(len(uniq), int)
    if strata is not None:
        smap = {}
        for s, d in zip(np.asarray(subjects).astype(str), np.asarray(strata).astype(str)):
            smap.setdefault(s, d)
        _, st = np.unique([smap[u] for u in uniq], return_inverse=True)
    rng = np.random.default_rng(seed)
    W = np.zeros((n_boot, len(uniq)))
    for g in np.unique(st):
        idx = np.flatnonzero(st == g)
        draws = rng.integers(0, len(idx), (n_boot, len(idx)))
        for b in range(n_boot):
            np.add.at(W[b], idx[draws[b]], 1.0)
    boot = _prf(*(W @ c).T)
    ci = {k: [float(np.nanquantile(v, 0.025)), float(np.nanquantile(v, 0.975))] if np.isfinite(v).any() else None
          for k, v in boot.items()}
    n_pos, n_neg = int(y.sum()), int((~y).sum())
    return {"threshold": float(threshold), **point, "ci95": ci, "n_windows": int(len(y)), "n_gait": n_pos,
            "n_non_gait": n_neg, "n_subjects": int(len(uniq)), "n_predicted_gait": int(pred.sum()),
            "small_sample": bool(len(uniq) < SMALL_SUBJECTS or n_pos < SMALL_WINDOWS or n_neg < SMALL_WINDOWS)}


def auroc_report(p: np.ndarray, y: np.ndarray, subjects: np.ndarray, strata: Optional[np.ndarray] = None,
                 n_boot: int = N_BOOT_AUC) -> Dict:
    from ..inertia.bootstrap import cluster_bootstrap
    from ..inertia.metrics import binary_auc
    p, y = np.asarray(p, float), np.asarray(y, bool)
    f = lambda idx: binary_auc(p[idx][~y[idx]], p[idx][y[idx]])  # noqa: E731
    r = cluster_bootstrap(f, subjects, strata=strata, n_boot=n_boot, seed=SEED)
    return {"auroc": r["point"], "ci95": [r["ci_low"], r["ci_high"]], "n_boot": r["n_boot"],
            "warning": r["warning"]}


def ece(p: np.ndarray, y: np.ndarray, n_bins: int = 15) -> float:
    from ..inertia.metrics import ece_binary
    return float(ece_binary(np.asarray(p, float), np.asarray(y, bool), n_bins))


def risk_coverage_summary(p: np.ndarray, y: np.ndarray, threshold: float) -> Dict:
    """Selective risk of the thresholded decision when abstaining on the least confident windows."""
    from ..inertia.abstention import aurc, risk_coverage
    p, y = np.asarray(p, float), np.asarray(y, bool)
    conf = np.maximum(p, 1 - p)
    correct = (p >= threshold) == y
    curve = risk_coverage(conf, correct, max_points=60)
    cov, risk = np.array(curve["coverage"]), np.array(curve["risk"])
    at = {f"risk_at_{int(c * 100)}pct": float(risk[np.searchsorted(cov, c, side="left").clip(0, len(cov) - 1)])
          for c in (0.5, 0.8, 0.9) if len(cov)}
    return {**aurc(conf, correct), **at, "curve": curve}


__all__ = ["N_BOOT", "N_BOOT_AUC", "SEED", "counts_by_subject", "binary_report", "auroc_report", "ece",
           "risk_coverage_summary"]
