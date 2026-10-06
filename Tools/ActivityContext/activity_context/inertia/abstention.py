"""Per-class operating points (VAL only), the one-shot test gate, risk-coverage (ported from Agent E).

A window is ACCEPTED as class c iff argmax q = c and q_c >= tau_c; it is correct iff c is in its truth set.

* strong : smallest tau on the grid such that AT tau the one-sided 95% Clopper-Pearson lower bound on
  precision >= 0.95 with n_acc >= 60, recall >= 0.10 and accepted windows from >= min(3, subjects with
  the class) val subjects, AND point precision >= 0.95 at every tau' >= tau with n_acc >= 60.
* weak   : otherwise, the same with point precision >= 0.80 and n_acc >= 30.
* abstain: neither; ``merge_into`` = the non-abstained supported class it is most confused with on val.

Test gate (:func:`check_gate`, run ONCE with the frozen tau): a strong class must reach point precision
>= 0.95, CP95 lower >= 0.90, n_acc >= 30 and recall >= 0.05 or it is DEMOTED to weak; the gate never promotes.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence

import numpy as np
from scipy.stats import beta

DEFAULT_GRID = np.round(np.arange(0.30, 0.9951, 0.005), 3)
FIXED_THRESHOLDS = (0.5, 0.6, 0.7, 0.8, 0.9, 0.95)


def clopper_pearson_lower(k: int, n: int, alpha: float = 0.05) -> float:
    if n == 0 or k == 0:
        return 0.0
    return float(beta.ppf(alpha, k, n - k + 1))


def class_curve(probs: np.ndarray, truth: np.ndarray, subjects: np.ndarray, c: int,
                grid: Sequence[float] = DEFAULT_GRID) -> List[Dict]:
    pred = probs.argmax(axis=1)
    qc = probs[:, c]
    is_c = truth[:, c]
    n_true = int(is_c.sum())
    rows = []
    for t in grid:
        acc = (pred == c) & (qc >= t)
        n = int(acc.sum())
        k = int((acc & is_c).sum())
        rows.append({"tau": float(t), "n_acc": n, "tp": k, "precision": k / n if n else float("nan"),
                     "cp_lower_95": clopper_pearson_lower(k, n), "recall": k / n_true if n_true else 0.0,
                     "n_subjects_acc": int(len(np.unique(subjects[acc]))) if n else 0})
    return rows


def _stable_min_tau(rows: List[Dict], ok_at, ok_above, n_min: int) -> Optional[int]:
    best = None
    for i in range(len(rows) - 1, -1, -1):
        r = rows[i]
        if r["n_acc"] < n_min:
            continue
        if not ok_above(r):
            break
        if ok_at(r):
            best = i
    return best


def select_operating_point(probs: np.ndarray, truth: np.ndarray, subjects: np.ndarray, c: int, supported: bool,
                           target: float = 0.95, weak_precision: float = 0.80, n_min_strong: int = 60,
                           n_min_weak: int = 30, min_recall: float = 0.10, min_subjects: int = 3,
                           grid: Sequence[float] = DEFAULT_GRID) -> Dict:
    n_val = int(truth[:, c].sum())
    if not supported or n_val < n_min_weak:
        return {"status": "abstain", "tau": 1.0, "n_val_class": n_val,
                "reason": "unsupported" if not supported else f"only {n_val} val windows"}
    rows = class_curve(probs, truth, subjects, c, grid)
    need = min(min_subjects, max(1, len(np.unique(subjects[truth[:, c]]))))
    i = _stable_min_tau(rows, lambda r: r["cp_lower_95"] >= target, lambda r: r["precision"] >= target, n_min_strong)
    if i is not None and rows[i]["recall"] >= min_recall and rows[i]["n_subjects_acc"] >= need:
        return {"status": "strong", "tau": rows[i]["tau"], "evidence": rows[i], "n_val_class": n_val,
                "rule": f"CP95 lower >= {target} at tau; precision >= {target} for all tau' >= tau (n_acc >= {n_min_strong})"}
    i = _stable_min_tau(rows, lambda r: r["precision"] >= weak_precision, lambda r: r["precision"] >= weak_precision,
                        n_min_weak)
    if i is not None and rows[i]["recall"] >= min_recall and rows[i]["n_subjects_acc"] >= need:
        return {"status": "weak", "tau": rows[i]["tau"], "evidence": rows[i], "n_val_class": n_val,
                "rule": f"precision >= {weak_precision} for all tau' >= tau (n_acc >= {n_min_weak})"}
    return {"status": "abstain", "tau": 1.0, "n_val_class": n_val, "reason": "no stable operating point"}


def merge_partners(probs: np.ndarray, truth: np.ndarray, status: Dict[str, str], class_order: Sequence[str]) -> Dict[str, str]:
    """Abstained class -> the non-abstained supported class it is most confused with on val (both directions)."""
    from .metrics import attributed_truth, confusion
    K = len(class_order)
    y, _ = attributed_truth(probs, truth)
    cm = confusion(y, probs.argmax(axis=1), K)
    sym = cm + cm.T
    live = [k for k, c in enumerate(class_order) if status.get(c) in ("strong", "weak")]
    out = {}
    for k, c in enumerate(class_order):
        if status.get(c) != "abstain" or not live:
            continue
        best = max(live, key=lambda d: (sym[k, d], -d))
        out[c] = class_order[best]
    return out


def check_gate(probs_test: np.ndarray, truth_test: np.ndarray, c: int, tau: float, target: float = 0.95,
               cp_floor: float = 0.90, n_min: int = 30, min_recall: float = 0.05) -> Dict:
    pred = probs_test.argmax(axis=1)
    acc = (pred == c) & (probs_test[:, c] >= tau)
    n, k = int(acc.sum()), int((acc & truth_test[:, c]).sum())
    n_true = int(truth_test[:, c].sum())
    prec = k / n if n else float("nan")
    rec = k / n_true if n_true else 0.0
    lb = clopper_pearson_lower(k, n)
    return {"tau": tau, "n_acc": n, "tp": k, "precision": prec, "cp_lower_95": lb, "recall": rec, "n_true": n_true,
            "pass": bool(n >= n_min and prec >= target and lb >= cp_floor and rec >= min_recall)}


def apply_gate(val_status: str, gate: Optional[Dict]) -> str:
    """Final status after the one-shot test gate: strong may be demoted to weak, nothing is promoted."""
    if val_status == "strong" and gate is not None and not gate["pass"]:
        return "weak"
    return val_status


def risk_coverage(conf: np.ndarray, correct: np.ndarray, max_points: int = 200) -> Dict[str, List[float]]:
    order = np.argsort(-conf, kind="stable")
    c, e = conf[order], (~correct[order]).astype(np.float64)
    n = np.arange(1, len(c) + 1)
    last = np.r_[c[1:] != c[:-1], True]
    thr, cov, risk = c[last], n[last] / len(c), np.cumsum(e)[last] / n[last]
    if len(thr) > max_points:
        pick = np.unique(np.linspace(0, len(thr) - 1, max_points).round().astype(int))
        thr, cov, risk = thr[pick], cov[pick], risk[pick]
    return {"threshold": thr.tolist(), "coverage": cov.tolist(), "risk": risk.tolist()}


def aurc(conf: np.ndarray, correct: np.ndarray) -> Dict[str, float]:
    if not len(conf):
        return {"aurc": float("nan"), "e_aurc": float("nan"), "risk_full_coverage": float("nan")}
    order = np.argsort(-conf, kind="stable")
    c, e = conf[order], (~correct[order]).astype(np.float64)
    n = np.arange(1, len(c) + 1)
    cum = np.cumsum(e)
    last = np.r_[c[1:] != c[:-1], True]
    group_end = np.flip(np.minimum.accumulate(np.flip(np.where(last, np.arange(len(c)), len(c)))))
    a = float((cum[group_end] / n[group_end]).mean())
    oracle = float(np.mean(np.cumsum(np.sort(e)) / n))
    return {"aurc": a, "e_aurc": a - oracle, "risk_full_coverage": float(e.mean()), "aurc_oracle": oracle}


def at_fixed_thresholds(probs: np.ndarray, truth: np.ndarray, thresholds: Sequence[float] = FIXED_THRESHOLDS) -> List[Dict]:
    conf = probs.max(axis=1)
    correct = truth[np.arange(len(conf)), probs.argmax(axis=1)]
    out = []
    for t in thresholds:
        a = conf >= t
        n = int(a.sum())
        out.append({"tau": t, "coverage": n / len(conf) if len(conf) else 0.0, "n_acc": n,
                    "precision": float(correct[a].mean()) if n else None})
    return out


def combined_risk_coverage(conf: np.ndarray, correct: np.ndarray, ood_score: np.ndarray,
                           ood_threshold: Optional[float]) -> Dict[str, float]:
    """Pooled ID + OOD set; acceptance needs ood_score <= threshold AND confidence (OOD windows count as errors)."""
    gate = np.ones(len(conf), bool) if ood_threshold is None else ood_score <= ood_threshold
    c = np.where(gate, conf, -np.inf)
    order = np.argsort(-c, kind="stable")
    k = int(np.isfinite(c).sum())
    risk = np.cumsum((~correct[order]).astype(float)) / np.arange(1, len(c) + 1)
    return {"max_coverage": k / len(c) if len(c) else 0.0,
            "aurc_within_max_coverage": float(risk[:k].mean()) if k else float("nan"),
            "risk_at_max_coverage": float(risk[k - 1]) if k else float("nan")}


__all__ = ["select_operating_point", "check_gate", "apply_gate", "merge_partners", "class_curve", "risk_coverage",
           "aurc", "at_fixed_thresholds", "combined_risk_coverage", "clopper_pearson_lower", "FIXED_THRESHOLDS"]
