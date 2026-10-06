"""Per-class operating points (VAL only), the one-shot test gate, risk-coverage (ported from Agent E).

A window is ACCEPTED as class c iff argmax q = c and q_c >= tau_c; it is correct iff c is in its truth set.

VAL operating points (:func:`select_operating_point`); every rule is evaluated AT tau and the point precision
must also hold at every tau' >= tau (stability). "Cluster q05" is the 5 % quantile of the accepted-window
precision over a subject-cluster bootstrap of the head's val subjects (:data:`CLUSTER_BOOT` resamples, fixed
seed; a resample with no accepted window counts as precision 0), so a class carried by one or two val
subjects cannot pass:

* strong : n_acc >= 60, one-sided 95 % Clopper-Pearson lower bound >= 0.95, cluster q05 >= 0.95, recall
  >= 0.10, accepted windows from >= 5 distinct val subjects; and >= 5 val subjects carry the class at all
  (a class seen in fewer than 5 val subjects is at most weak).
* weak   : n_acc >= 30, point precision >= 0.80, cluster q05 >= 0.70, recall >= 0.10, accepted windows from
  >= min(5, val subjects with the class) distinct val subjects.
* abstain: neither. ``merge_into`` (:func:`merge_partners`) only names a partner inside the static
  semantic-compatibility table :data:`MERGE_COMPAT` that is itself strong/weak; otherwise the abstained
  class has no partner and the decoder drops (renormalises away) its mass.

Test gate (:func:`check_gate` per pooled test set and per wrist dataset, run ONCE with the frozen VAL tau)
returns the highest status the test evidence supports (``level``):

* ``strong`` iff n_acc >= 30, precision >= 0.95, CP95 lower >= 0.90 and recall >= 0.05 (pooled) — a
  dataset-level check only needs precision >= 0.95 at n_acc >= 30;
* otherwise ``weak`` iff precision >= 0.80 or n_acc < 30 (too few accepted windows to demote a weak class);
* otherwise ``abstain``.

The final status is the minimum of the VAL status, the pooled level and every dataset level that has
n_acc >= 30 (:func:`final_status`): the gate only ever demotes.
"""

from __future__ import annotations

from typing import Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np
from scipy.stats import beta

DEFAULT_GRID = np.round(np.arange(0.30, 0.9951, 0.005), 3)
FIXED_THRESHOLDS = (0.5, 0.6, 0.7, 0.8, 0.9, 0.95)

STATUS_RANK = {"abstain": 0, "weak": 1, "strong": 2}
STRONG_PRECISION = 0.95
WEAK_PRECISION = 0.80
STRONG_CLUSTER_Q05 = 0.95
WEAK_CLUSTER_Q05 = 0.70
MIN_STRONG_SUBJECTS = 5
CLUSTER_BOOT = 1000
CLUSTER_SEED = 0
CLUSTER_QUANTILE = 0.05
GATE_N_MIN = 30
GATE_CP_FLOOR = 0.90
GATE_MIN_RECALL = 0.05

# Static semantic-compatibility table for abstained-class merging (G-19): an abstained class may only be
# merged into one of these partners (and only if that partner is strong/weak); pairs are symmetric.
MERGE_PAIRS: Dict[str, Tuple[Tuple[str, str], ...]] = {
    "posture": (("postural_transition", "upright_stationary"),),
    "locomotion": (("brisk_walking", "walking"), ("stairs", "walking")),
    "arm_behavior": (("quiet", "desk_like"),),
}
MERGE_COMPAT: Dict[str, Dict[str, Tuple[str, ...]]] = {}
for _h, _pairs in MERGE_PAIRS.items():
    _m: Dict[str, List[str]] = {}
    for _a, _b in _pairs:
        _m.setdefault(_a, []).append(_b)
        _m.setdefault(_b, []).append(_a)
    MERGE_COMPAT[_h] = {k: tuple(v) for k, v in _m.items()}


def min_status(*statuses: str) -> str:
    """The weakest of the given statuses (strong > weak > abstain)."""
    return min(statuses, key=lambda s: STATUS_RANK[s])


def clopper_pearson_lower(k: int, n: int, alpha: float = 0.05) -> float:
    if n == 0 or k == 0:
        return 0.0
    return float(beta.ppf(alpha, k, n - k + 1))


def cluster_precision_quantile(probs: np.ndarray, truth: np.ndarray, subjects: np.ndarray, c: int,
                               grid: Sequence[float] = DEFAULT_GRID, n_boot: int = CLUSTER_BOOT,
                               seed: int = CLUSTER_SEED, q: float = CLUSTER_QUANTILE) -> np.ndarray:
    """``q`` quantile (per tau of ``grid``) of the accepted-window precision over a subject-cluster bootstrap.

    Subjects are the distinct values of ``subjects`` (every scored window of the head, not only class-c
    windows), resampled with replacement ``n_boot`` times (``numpy.random.default_rng(seed)``); the same
    resamples are used for every tau. A resample with no accepted window counts as precision 0."""
    grid = np.asarray(grid, float)
    subj = np.asarray(subjects).astype(str)
    if not len(subj):
        return np.zeros(len(grid))
    uniq, si = np.unique(subj, return_inverse=True)
    S, G = len(uniq), len(grid)
    pred = probs.argmax(axis=1)
    acc_any = pred == c
    # window accepted at grid point g iff q_c >= grid[g]: the number of grid points <= q_c
    k = np.searchsorted(grid, probs[:, c], side="right")
    hist_n = np.zeros((S, G + 1))
    hist_t = np.zeros((S, G + 1))
    np.add.at(hist_n, (si[acc_any], k[acc_any]), 1.0)
    tp = acc_any & truth[:, c]
    np.add.at(hist_t, (si[tp], k[tp]), 1.0)
    # n_acc[s, g] = windows of s with k > g  (reverse cumulative sum over k = g+1..G)
    n_s = np.flip(np.cumsum(np.flip(hist_n, axis=1), axis=1), axis=1)[:, 1:]
    t_s = np.flip(np.cumsum(np.flip(hist_t, axis=1), axis=1), axis=1)[:, 1:]
    rng = np.random.default_rng(seed)
    W = np.stack([np.bincount(rng.integers(0, S, S), minlength=S) for _ in range(n_boot)]).astype(float)
    n_b, t_b = W @ n_s, W @ t_s
    prec = np.divide(t_b, n_b, out=np.zeros_like(t_b), where=n_b > 0)
    return np.quantile(prec, q, axis=0)


def class_curve(probs: np.ndarray, truth: np.ndarray, subjects: np.ndarray, c: int,
                grid: Sequence[float] = DEFAULT_GRID, cluster: bool = False) -> List[Dict]:
    pred = probs.argmax(axis=1)
    qc = probs[:, c]
    is_c = truth[:, c]
    n_true = int(is_c.sum())
    q05 = cluster_precision_quantile(probs, truth, subjects, c, grid) if cluster else None
    rows = []
    for i, t in enumerate(grid):
        acc = (pred == c) & (qc >= t)
        n = int(acc.sum())
        k = int((acc & is_c).sum())
        r = {"tau": float(t), "n_acc": n, "tp": k, "precision": k / n if n else float("nan"),
             "cp_lower_95": clopper_pearson_lower(k, n), "recall": k / n_true if n_true else 0.0,
             "n_subjects_acc": int(len(np.unique(subjects[acc]))) if n else 0}
        if q05 is not None:
            r["cluster_q05"] = float(q05[i])
        rows.append(r)
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
                           target: float = STRONG_PRECISION, weak_precision: float = WEAK_PRECISION,
                           n_min_strong: int = 60, n_min_weak: int = 30, min_recall: float = 0.10,
                           min_subjects: int = MIN_STRONG_SUBJECTS, strong_q05: float = STRONG_CLUSTER_Q05,
                           weak_q05: float = WEAK_CLUSTER_Q05, grid: Sequence[float] = DEFAULT_GRID) -> Dict:
    """VAL operating point of class ``c`` (module docstring). ``subjects`` = the val subject of every row."""
    n_val = int(truth[:, c].sum())
    if not supported or n_val < n_min_weak:
        return {"status": "abstain", "tau": 1.0, "n_val_class": n_val,
                "reason": "unsupported" if not supported else f"only {n_val} val windows"}
    rows = class_curve(probs, truth, subjects, c, grid, cluster=True)
    n_subj_class = int(len(np.unique(np.asarray(subjects)[truth[:, c]])))
    need = min(min_subjects, max(1, n_subj_class))
    common = {"n_val_class": n_val, "n_val_subjects_class": n_subj_class,
              "cluster_bootstrap": {"n_boot": CLUSTER_BOOT, "seed": CLUSTER_SEED, "quantile": CLUSTER_QUANTILE,
                                    "unit": "val subject (all subjects scored by the head)"}}
    if n_subj_class >= min_subjects:
        i = _stable_min_tau(rows, lambda r: r["cp_lower_95"] >= target and r["cluster_q05"] >= strong_q05,
                            lambda r: r["precision"] >= target, n_min_strong)
        if i is not None and rows[i]["recall"] >= min_recall and rows[i]["n_subjects_acc"] >= min_subjects:
            return {"status": "strong", "tau": rows[i]["tau"], "evidence": rows[i], **common,
                    "rule": f"at tau: CP95 lower >= {target}, cluster q05 >= {strong_q05}, recall >= {min_recall}, "
                            f">= {min_subjects} accepted val subjects; precision >= {target} for all tau' >= tau "
                            f"(n_acc >= {n_min_strong})"}
    i = _stable_min_tau(rows, lambda r: r["precision"] >= weak_precision and r["cluster_q05"] >= weak_q05,
                        lambda r: r["precision"] >= weak_precision, n_min_weak)
    if i is not None and rows[i]["recall"] >= min_recall and rows[i]["n_subjects_acc"] >= need:
        out = {"status": "weak", "tau": rows[i]["tau"], "evidence": rows[i], **common,
               "rule": f"at tau: precision >= {weak_precision}, cluster q05 >= {weak_q05}, recall >= {min_recall}, "
                       f">= {need} accepted val subjects; precision >= {weak_precision} for all tau' >= tau "
                       f"(n_acc >= {n_min_weak})"}
        if n_subj_class < min_subjects:
            out["strong_ineligible"] = f"only {n_subj_class} val subjects carry the class (< {min_subjects})"
        return out
    return {"status": "abstain", "tau": 1.0, **common, "reason": "no stable operating point"}


def merge_confusion(probs: np.ndarray, truth: np.ndarray, class_order: Sequence[str]) -> List[List[int]]:
    """Symmetric (truth x prediction + transpose) val confusion used to rank merge partners."""
    from .metrics import attributed_truth, confusion
    y, _ = attributed_truth(probs, truth)
    cm = confusion(y, probs.argmax(axis=1), len(class_order))
    return (cm + cm.T).astype(int).tolist()


def merge_partners(status: Mapping[str, str], class_order: Sequence[str], head: str,
                   sym_confusion: Optional[Sequence[Sequence[int]]] = None) -> Dict[str, str]:
    """Abstained class -> a strong/weak partner from :data:`MERGE_COMPAT` (most confused on val, ties by
    class order). No compatible live partner -> no entry (the decoder drops the class)."""
    compat = MERGE_COMPAT.get(head, {})
    out = {}
    for k, c in enumerate(class_order):
        if status.get(c) != "abstain":
            continue
        cands = [p for p in compat.get(c, ()) if status.get(p) in ("strong", "weak")]
        if not cands:
            continue
        def rank(p):
            d = list(class_order).index(p)
            return (sym_confusion[k][d] if sym_confusion is not None else 0, -d)
        out[c] = max(cands, key=rank)
    return out


def evidence_groups(status: Mapping[str, str], merge_into: Mapping[str, str]) -> List[str]:
    """The decoder's evidence groups: one per strong/weak class (merged abstained classes join their
    partner; abstained classes without a partner are dropped)."""
    return [c for c, s in status.items() if s in ("strong", "weak")]


def check_gate(probs_test: np.ndarray, truth_test: np.ndarray, c: int, tau: float, target: float = STRONG_PRECISION,
               cp_floor: float = GATE_CP_FLOOR, n_min: int = GATE_N_MIN, min_recall: float = GATE_MIN_RECALL,
               weak_precision: float = WEAK_PRECISION, dataset_level: bool = False) -> Dict:
    """Test evidence at the frozen tau. ``pass`` = the strong criteria hold; ``level`` = the highest status the
    evidence supports (module docstring). ``dataset_level`` drops the CP/recall parts of the strong check."""
    pred = probs_test.argmax(axis=1)
    acc = (pred == c) & (probs_test[:, c] >= tau)
    n, k = int(acc.sum()), int((acc & truth_test[:, c]).sum())
    n_true = int(truth_test[:, c].sum())
    prec = k / n if n else float("nan")
    rec = k / n_true if n_true else 0.0
    lb = clopper_pearson_lower(k, n)
    strong = bool(n >= n_min and prec >= target and (dataset_level or (lb >= cp_floor and rec >= min_recall)))
    if strong:
        level = "strong"
    elif n < n_min or prec >= weak_precision:
        level = "weak"
    else:
        level = "abstain"
    return {"tau": tau, "n_acc": n, "tp": k, "precision": prec, "cp_lower_95": lb, "recall": rec, "n_true": n_true,
            "pass": strong, "level": level, "decisive": bool(n >= n_min)}


def _level(gate: Mapping) -> str:
    if "level" in gate:
        return gate["level"]
    return "strong" if gate.get("pass") else "weak"


def apply_gate(val_status: str, gate: Optional[Mapping]) -> str:
    """Final status after ONE gate: min(val status, gate level); nothing is ever promoted."""
    if gate is None or val_status == "abstain":
        return val_status
    return min_status(val_status, _level(gate))


def final_status(val_status: str, pooled: Optional[Mapping],
                 per_dataset: Optional[Mapping[str, Mapping]] = None) -> Tuple[str, List[str]]:
    """min(val, pooled level, every decisive (n_acc >= 30) dataset level) and the demotion reasons."""
    out, reasons = val_status, []
    if val_status == "abstain":
        return out, reasons
    if pooled is not None:
        new = apply_gate(out, pooled)
        if new != out:
            reasons.append(f"pooled test: precision {pooled.get('precision'):.3f} at n_acc {pooled.get('n_acc')} -> {new}")
        out = new
    for d, g in sorted((per_dataset or {}).items()):
        if not g.get("decisive", g.get("n_acc", 0) >= GATE_N_MIN):
            continue
        new = apply_gate(out, g)
        if new != out:
            reasons.append(f"{d} test: precision {g.get('precision'):.3f} at n_acc {g.get('n_acc')} -> {new}")
        out = new
    return out, reasons


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


__all__ = ["select_operating_point", "check_gate", "apply_gate", "final_status", "merge_partners", "merge_confusion",
           "evidence_groups", "class_curve", "cluster_precision_quantile", "risk_coverage", "aurc",
           "at_fixed_thresholds", "combined_risk_coverage", "clopper_pearson_lower", "min_status", "FIXED_THRESHOLDS",
           "MERGE_COMPAT", "MERGE_PAIRS", "STATUS_RANK"]
