"""Classification + calibration metrics (ported from Agent E's ``nara_eval.metrics``, made set-aware).

Conventions
-----------
* ``probs`` float64 [N, K] over the head's FULL class order; unsupported classes carry exactly 0.
* Truth is a **set** per window: ``truth`` bool [N, K] (after support resolution, i.e. covered classes are
  already folded into their cover). A singleton set is an ordinary label. Rows with an empty set are
  removed by the caller and counted (never silently scored).
* Hit = argmax in the truth set. The *attributed* truth (for confusion, P/R/F1, classwise ECE) is the
  argmax when it is a hit, else the set member with the highest probability (ties -> class order).
* NLL = -log sum_{k in S} p_k; Brier = set Brier (S collapsed to one outcome; equals the multiclass
  Brier sum_k (p_k - 1[y=k])^2, range [0, 2], for singleton truth).
* Headline ECE = top-label, 15 equal-width bins, always with the consistency-resampling null reference;
  equal-mass is secondary. Binning follows ``sklearn.calibration.calibration_curve``.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

EPS = 1e-12


def attributed_truth(probs: np.ndarray, truth: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """(y_att int [N], hit bool [N])."""
    pred = probs.argmax(axis=1)
    hit = truth[np.arange(len(pred)), pred]
    masked = np.where(truth, probs, -np.inf)
    best = masked.argmax(axis=1)
    return np.where(hit, pred, best), hit


def nll(probs: np.ndarray, truth: np.ndarray) -> float:
    p = (probs * truth).sum(axis=1)
    return float(-np.mean(np.log(np.clip(p, EPS, 1.0))))


def brier(probs: np.ndarray, truth: np.ndarray) -> float:
    in_set = (probs * truth).sum(axis=1)
    out_sq = ((probs * ~truth) ** 2).sum(axis=1)
    return float(np.mean(out_sq + (in_set - 1.0) ** 2))


def _bin_ids(values: np.ndarray, n_bins: int, binning: str) -> Tuple[np.ndarray, int]:
    if binning == "equal_width":
        edges = np.linspace(0.0, 1.0, n_bins + 1)
    elif binning == "equal_mass":
        edges = np.percentile(values, np.linspace(0, 100, n_bins + 1))
    else:
        raise ValueError(f"unknown binning {binning!r}")
    return np.searchsorted(edges[1:-1], values), len(edges)


def reliability_bins(conf: np.ndarray, correct: np.ndarray, n_bins: int = 15, binning: str = "equal_width"):
    ids, nb = _bin_ids(conf, n_bins, binning)
    cnt = np.bincount(ids, minlength=nb)
    s_conf = np.bincount(ids, weights=conf, minlength=nb)
    s_acc = np.bincount(ids, weights=correct.astype(np.float64), minlength=nb)
    nz = cnt > 0
    return {"count": cnt[nz], "conf": s_conf[nz] / cnt[nz], "acc": s_acc[nz] / cnt[nz]}


def _ece(b) -> float:
    n = b["count"].sum()
    return float(np.sum(b["count"] / n * np.abs(b["acc"] - b["conf"]))) if n else float("nan")


def ece_top(probs: np.ndarray, truth: np.ndarray, n_bins: int = 15, binning: str = "equal_width") -> float:
    _, hit = attributed_truth(probs, truth)
    return _ece(reliability_bins(probs.max(axis=1), hit, n_bins, binning))


def ece_binary(p: np.ndarray, y: np.ndarray, n_bins: int = 15, binning: str = "equal_width") -> float:
    return _ece(reliability_bins(np.asarray(p, float), np.asarray(y, bool), n_bins, binning))


def classwise_ece(probs: np.ndarray, y_att: np.ndarray, support_mask: np.ndarray, n_bins: int = 15,
                  binning: str = "equal_width") -> Tuple[float, Dict[int, float]]:
    per = {k: ece_binary(probs[:, k], y_att == k, n_bins, binning) for k in range(probs.shape[1]) if support_mask[k]}
    return (float(np.mean(list(per.values()))) if per else float("nan")), per


def ece_null_reference(conf: np.ndarray, n_bins: int = 15, binning: str = "equal_width", n_rep: int = 200,
                       seed: int = 0) -> Dict[str, float]:
    """ECE a perfectly calibrated head would show at this n and confidence distribution (Broecker & Smith)."""
    rng = np.random.default_rng(seed)
    v = np.array([_ece(reliability_bins(conf, rng.random(len(conf)) < conf, n_bins, binning)) for _ in range(n_rep)])
    return {"null_mean": float(v.mean()), "null_p95": float(np.quantile(v, 0.95))}


def confusion(y: np.ndarray, yhat: np.ndarray, K: int) -> np.ndarray:
    """Rows = truth, cols = prediction (sklearn convention)."""
    idx = np.asarray(y, np.int64) * K + np.asarray(yhat, np.int64)
    return np.bincount(idx, minlength=K * K).reshape(K, K).astype(np.int64)


def per_class_prf(cm: np.ndarray) -> Dict[str, np.ndarray]:
    tp = np.diag(cm).astype(np.float64)
    pred = cm.sum(axis=0).astype(np.float64)
    true = cm.sum(axis=1).astype(np.float64)
    prec = np.divide(tp, pred, out=np.zeros_like(tp), where=pred > 0)
    rec = np.divide(tp, true, out=np.zeros_like(tp), where=true > 0)
    f1 = np.divide(2 * prec * rec, prec + rec, out=np.zeros_like(tp), where=(prec + rec) > 0)
    return {"precision": prec, "recall": rec, "f1": f1, "support": true.astype(np.int64), "predicted": pred.astype(np.int64)}


def balanced_accuracy(cm: np.ndarray) -> float:
    true = cm.sum(axis=1)
    present = true > 0
    return float(np.mean(np.diag(cm)[present] / true[present])) if present.any() else float("nan")


def macro_f1(cm: np.ndarray, classes: Optional[Sequence[int]] = None) -> float:
    """Macro-F1 over ``classes``; default = the union of true and predicted labels (sklearn's
    ``f1_score(average="macro")`` without ``labels=``): a class predicted while absent scores F1 0."""
    prf = per_class_prf(cm)
    if classes is None:
        classes = union_classes(cm)
    classes = list(classes)
    return float(np.mean(prf["f1"][classes])) if classes else float("nan")


def union_classes(cm: np.ndarray) -> List[int]:
    prf = per_class_prf(cm)
    return [int(k) for k in np.where((prf["support"] > 0) | (prf["predicted"] > 0))[0]]


def single_label_prf(probs: np.ndarray, truth: np.ndarray, class_order: List[str],
                     support_mask: np.ndarray) -> Dict[str, Any]:
    """Per-class P/R/F1 on windows whose truth is ONE class (set-target windows excluded), next to the
    set-aware scoring of :func:`head_report` (where a set window counts as correct for any member)."""
    single = truth.sum(axis=1) == 1
    out: Dict[str, Any] = {"n_single_label": int(single.sum()), "n_set_target": int((truth.sum(axis=1) > 1).sum()),
                           "per_class": {}}
    if not single.any():
        return out
    y = truth[single].argmax(axis=1)
    cm = confusion(y, probs[single].argmax(axis=1), len(class_order))
    prf = per_class_prf(cm)
    for k, c in enumerate(class_order):
        if support_mask[k]:
            out["per_class"][c] = {"precision": float(prf["precision"][k]), "recall": float(prf["recall"][k]),
                                   "f1": float(prf["f1"][k]), "support": int(prf["support"][k]),
                                   "predicted": int(prf["predicted"][k])}
    out["macro_f1"] = macro_f1(cm)
    return out


def head_report(probs: np.ndarray, truth: np.ndarray, class_order: List[str], support_mask: np.ndarray,
                n_bins: int = 15, null_reps: int = 200, unsupported_truth_counts: Optional[Dict[str, int]] = None) -> Dict:
    """Spec §14/§22 metrics for one head on one split; every class listed (poor ones are not hidden)."""
    keep = truth.any(axis=1)
    probs, truth = probs[keep], truth[keep]
    K = len(class_order)
    if not len(probs):
        return {"n": 0, "n_dropped_empty_truth": int((~keep).sum())}
    y_att, hit = attributed_truth(probs, truth)
    yhat = probs.argmax(axis=1)
    cm = confusion(y_att, yhat, K)
    prf = per_class_prf(cm)
    cw_mean, cw = classwise_ece(probs, y_att, support_mask, n_bins, "equal_width")
    conf = probs.max(axis=1)
    sup_idx = [k for k in range(K) if support_mask[k]]
    present = [k for k in sup_idx if prf["support"][k] > 0]
    union = union_classes(cm)
    unsup = unsupported_truth_counts or {}
    return {
        "n": int(len(probs)), "n_dropped_empty_truth": int((~keep).sum()),
        "n_set_truth": int((truth.sum(axis=1) > 1).sum()),
        "accuracy": float(hit.mean()), "nll": nll(probs, truth), "brier": brier(probs, truth),
        "ece_top_equal_width_15": ece_top(probs, truth, n_bins, "equal_width"),
        "ece_top_equal_width_15_null": ece_null_reference(conf, n_bins, "equal_width", n_rep=null_reps),
        "ece_top_equal_mass_15": ece_top(probs, truth, n_bins, "equal_mass"),
        "classwise_ece_equal_width_15": cw_mean,
        "balanced_accuracy": balanced_accuracy(cm),
        # headline: sklearn convention (union of true and predicted labels; predicted-but-absent classes = F1 0)
        "macro_f1": macro_f1(cm, union), "macro_f1_classes": [class_order[k] for k in union],
        "predicted_absent_classes": [class_order[k] for k in union if prf["support"][k] == 0],
        # legacy number, clearly labelled: only classes WITH test support (ignores false alarms of absent classes)
        "macro_f1_present_supported": macro_f1(cm, present),
        "per_class": {class_order[k]: {
            "precision": float(prf["precision"][k]), "recall": float(prf["recall"][k]), "f1": float(prf["f1"][k]),
            "support": int(prf["support"][k]), "predicted": int(prf["predicted"][k]),
            "classwise_ece": cw.get(k), "supported_by_head": bool(support_mask[k]),
            "unsupported_truth_windows": int(unsup.get(class_order[k], 0))} for k in range(K)},
        "confusion": {"rows_truth_cols_pred": list(class_order), "matrix": cm.tolist()},
    }


def binary_auc(score_neg: np.ndarray, score_pos: np.ndarray) -> float:
    """Mann-Whitney AUROC (positives score higher), mid-ranks for ties."""
    from scipy.stats import rankdata
    if not len(score_neg) or not len(score_pos):
        return float("nan")
    r = rankdata(np.concatenate([score_neg, score_pos]))
    n1, n0 = len(score_pos), len(score_neg)
    return float((r[n0:].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))


def average_precision(score_neg: np.ndarray, score_pos: np.ndarray) -> float:
    s = np.concatenate([score_neg, score_pos])
    lab = np.concatenate([np.zeros(len(score_neg)), np.ones(len(score_pos))])
    if not lab.sum():
        return float("nan")
    order = np.argsort(-s, kind="mergesort")
    s, lab = s[order], lab[order]
    distinct = np.r_[s[1:] != s[:-1], True]
    tp, fp = np.cumsum(lab)[distinct], np.cumsum(1 - lab)[distinct]
    prec, rec = tp / (tp + fp), tp / lab.sum()
    return float(np.sum((rec - np.r_[0.0, rec[:-1]]) * prec))


__all__ = ["attributed_truth", "nll", "brier", "ece_top", "ece_binary", "classwise_ece", "ece_null_reference",
           "confusion", "per_class_prf", "balanced_accuracy", "macro_f1", "union_classes", "single_label_prf",
           "head_report", "binary_auc",
           "average_precision", "reliability_bins"]
