"""OOD / novelty scores on the frozen embedding (ported from Agent E; scored with ``bundle_math``).

Fit on TRAIN embeddings, threshold on VAL in-distribution windows, never on test. Scores (higher = novel):

* ``maha_min``    min over fine source-activity keys (``dataset|label``, >= 50 train windows) of the
                  Mahalanobis distance with the Ledoit-Wolf-shrunk pooled within-class covariance (Lee 2018)
* ``maha_global`` distance to one Ledoit-Wolf Gaussian of all train windows
* ``maha_rel``    maha_min - maha_global (Ren 2021) — benchmarked only (not a bundle method)
* ``knn``         k-th nearest-neighbour distance between L2-normalised z-scored embeddings and a deterministic
                  4096-window train reference (hash-ranked within dataset|label strata), stored float16
* ``energy``      -logsumexp of a softmax head's raw supported logits (Liu 2020)

All z-scoring uses the OOD reference's own ``mu``/``sigma`` (train). Distances are square roots (as the
bundle computes them). The threshold is the 0.95 quantile (``higher``) of VAL ID scores (5% false alarms).
"""

from __future__ import annotations

import hashlib
from typing import Any, Dict, List, Optional, Sequence

import numpy as np

from . import bundle_math as bm
from . import metrics as M

BENCH_METHODS = ("maha_min", "maha_global", "maha_rel", "knn", "energy")
BUNDLE_METHODS = ("maha_min", "maha_global", "knn", "energy")
N_REF = 4096
MIN_CLASS_N = 50
SALT = "nara-ood-ref-v1"


def _rank(keys: Sequence[str]) -> np.ndarray:
    return np.array([int(hashlib.sha256((SALT + k).encode()).hexdigest()[:16], 16) for k in keys], dtype=np.uint64)


def stratified_hash_subsample(keys: Sequence[str], strata: Sequence[str], n_total: int) -> np.ndarray:
    strata = np.asarray(strata).astype(str)
    if len(keys) <= n_total:
        return np.arange(len(keys))
    ranks = _rank(keys)
    uniq, counts = np.unique(strata, return_counts=True)
    quota = np.maximum(1, np.floor(counts / counts.sum() * n_total).astype(int))
    chosen = []
    for s, q in zip(uniq, quota):
        idx = np.flatnonzero(strata == s)
        chosen.append(idx[np.argsort(ranks[idx], kind="stable")[:q]])
    return np.sort(np.concatenate(chosen))[:n_total]


def maha_fast(z: np.ndarray, means: np.ndarray, precision: np.ndarray) -> np.ndarray:
    """min_c sqrt((z - m_c)^T P (z - m_c)) via z'Pz - 2 z'P m_c + m_c'P m_c (BLAS; O(B D^2 + B C D)).

    Algebraically identical to ``bundle_math.ood_maha_min`` / ``ood_maha_global`` (parity-tested to 1e-8),
    which materialise [B, C, D] and use a scalar three-operand einsum (O(B C D^2) without BLAS)."""
    z = np.asarray(z, np.float64)
    P = np.asarray(precision, np.float64)
    M = np.asarray(means, np.float64)
    zP = z @ P
    d2 = (zP * z).sum(axis=1)[:, None] - 2.0 * (zP @ M.T) + ((M @ P) * M).sum(axis=1)[None, :]
    return np.sqrt(np.maximum(d2.min(axis=1), 0.0))


class OODModel:
    """Fitted reference; ``arrays(method)`` gives the bundle's ood_reference.npz content."""

    def __init__(self, emb_train: np.ndarray, act_keys: Sequence[str], uids: Sequence[str],
                 n_ref: int = N_REF, min_class_n: int = MIN_CLASS_N):
        from sklearn.covariance import LedoitWolf
        e = np.asarray(emb_train, np.float64)
        self.mu = e.mean(axis=0)
        sd = e.std(axis=0)
        self.sigma = np.where(sd > 1e-6, sd, 1.0)
        z = (e - self.mu) / self.sigma
        keys = np.asarray(act_keys).astype(str)
        classes, counts = np.unique(keys, return_counts=True)
        self.classes = [str(c) for c, n in zip(classes, counts) if n >= min_class_n]
        if not self.classes:
            self.classes = [str(classes[np.argmax(counts)])]
        self.class_means = np.stack([z[keys == c].mean(axis=0) for c in self.classes])
        resid = np.concatenate([z[keys == c] - self.class_means[i] for i, c in enumerate(self.classes)])
        lw = LedoitWolf(assume_centered=True).fit(resid)
        lw0 = LedoitWolf().fit(z)
        self.precision = lw.precision_.astype(np.float64)
        self.global_mean = lw0.location_.astype(np.float64)
        self.global_precision = lw0.precision_.astype(np.float64)
        self.shrinkage = {"within": float(lw.shrinkage_), "global": float(lw0.shrinkage_)}
        sel = stratified_hash_subsample(list(uids), keys, n_ref)
        zr = z[sel]
        nr = np.linalg.norm(zr, axis=1, keepdims=True)
        self.reference = np.where(nr > 0, zr / np.where(nr > 0, nr, 1), 0).astype(np.float16)
        self.n_ref = int(len(sel))

    def z(self, emb: np.ndarray) -> np.ndarray:
        return bm.standardize(emb, self.mu, self.sigma)

    def score(self, method: str, emb: Optional[np.ndarray], raw_logits_supported: Optional[np.ndarray] = None,
              k: int = 10, chunk: int = 512) -> np.ndarray:
        """Row-chunked: bundle_math's Mahalanobis materialises [B, C, D], so B is bounded here."""
        n = len(raw_logits_supported) if method == "energy" else len(emb)
        if n > chunk:
            parts = [self.score(method, None if emb is None else emb[i:i + chunk],
                                None if raw_logits_supported is None else raw_logits_supported[i:i + chunk], k, chunk)
                     for i in range(0, n, chunk)]
            return np.concatenate(parts)
        if method == "energy":
            if raw_logits_supported is None:
                raise ValueError("energy needs the head's raw supported logits")
            return bm.ood_energy(raw_logits_supported)
        z = self.z(emb)
        if method == "maha_min":
            return maha_fast(z, self.class_means, self.precision)
        if method == "maha_global":
            return maha_fast(z, self.global_mean[None, :], self.global_precision)
        if method == "maha_rel":
            return maha_fast(z, self.class_means, self.precision) - maha_fast(z, self.global_mean[None, :],
                                                                              self.global_precision)
        if method == "knn":
            return bm.ood_knn(z, self.reference, int(k))
        raise ValueError(f"unknown OOD method {method!r}")

    def arrays(self, method: str) -> Dict[str, np.ndarray]:
        if method == "energy":
            return {}
        base = {"mu": self.mu, "sigma": self.sigma}
        if method == "maha_min":
            return dict(base, class_means=self.class_means, precision=self.precision)
        if method == "maha_global":
            return dict(base, mean=self.global_mean, precision=self.global_precision)
        if method == "knn":
            return dict(base, reference=self.reference)
        raise ValueError(f"{method} is not a bundle OOD method")


def fit_threshold(val_id_scores: np.ndarray, q: float = 0.95) -> float:
    return float(np.quantile(np.asarray(val_id_scores, np.float64), q, method="higher"))


def fpr_at_tpr(score_neg: np.ndarray, score_pos: np.ndarray, tpr: float = 0.95) -> float:
    if not len(score_pos) or not len(score_neg):
        return float("nan")
    thr = np.sort(score_pos)[::-1][int(np.ceil(tpr * len(score_pos))) - 1]
    return float(np.mean(score_neg >= thr))


def ood_report(score_id: np.ndarray, score_ood: np.ndarray, threshold: float) -> Dict[str, Any]:
    return {"n_id": int(len(score_id)), "n_ood": int(len(score_ood)),
            "ood_prevalence": len(score_ood) / max(len(score_id) + len(score_ood), 1),
            "auroc": M.binary_auc(score_id, score_ood), "auprc_ood_positive": M.average_precision(score_id, score_ood),
            "fpr95_ood_positive": fpr_at_tpr(score_id, score_ood),
            "fpr95_id_positive": fpr_at_tpr(-score_ood, -score_id),
            "threshold": threshold, "id_false_alarm_at_op": float(np.mean(score_id > threshold)) if len(score_id) else None,
            "ood_detect_rate_at_op": float(np.mean(score_ood > threshold)) if len(score_ood) else None}


def select_method(val_id: Dict[str, np.ndarray], val_ood: Dict[str, np.ndarray],
                  candidates: Sequence[str] = ("maha_min", "maha_global", "knn", "energy")) -> Dict[str, Any]:
    """Bundle method = highest VAL AUROC (held-out activities on val subjects vs val ID); ties -> list order."""
    rows = {m: M.binary_auc(val_id[m], val_ood[m]) for m in candidates if m in val_id and m in val_ood}
    best = max(rows, key=lambda m: (np.nan_to_num(rows[m], nan=-1.0), -list(candidates).index(m)))
    return {"chosen": best, "val_auroc": rows, "rule": "max VAL AUROC on the held-out-activity selection set"}


__all__ = ["OODModel", "fit_threshold", "ood_report", "select_method", "fpr_at_tpr", "stratified_hash_subsample",
           "BENCH_METHODS", "BUNDLE_METHODS", "N_REF"]
