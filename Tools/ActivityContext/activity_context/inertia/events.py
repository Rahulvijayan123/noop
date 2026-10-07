"""Transition-event extraction + matching metrics (ported from Agent E's ``nara_eval.events``).

Extraction (per recording, per event type, independently): local maxima of p_e[t] with p_e >= theta_e,
greedy NMS by descending p within a refractory period, event time = window centre of the peak.
Matching: one-to-one within +-tol (Hungarian: maximum cardinality, then minimum total |error|).
Predictions inside masked (label-uncertain) spans are discarded before matching (neither TP nor FP).
theta_e is chosen on VALIDATION recordings only (:func:`select_theta`).
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
from scipy.optimize import linear_sum_assignment

REFRACTORY_S = 10.0
THETA_GRID = tuple(np.round(np.arange(0.1, 0.951, 0.05), 3))


def extract_events(t: np.ndarray, p: np.ndarray, theta: float, refractory_s: float = REFRACTORY_S) -> np.ndarray:
    if len(p) == 0:
        return np.empty(0)
    left, right = np.r_[-np.inf, p[:-1]], np.r_[p[1:], -np.inf]
    cand = np.where((p >= theta) & (p > left) & (p >= right))[0]
    kept: List[int] = []
    for i in cand[np.argsort(-p[cand], kind="stable")]:
        if all(abs(t[i] - t[j]) >= refractory_s for j in kept):
            kept.append(int(i))
    return np.sort(t[np.array(kept, dtype=int)]) if kept else np.empty(0)


def drop_masked(times: np.ndarray, masked: Sequence[Tuple[float, float]]) -> np.ndarray:
    keep = np.ones(len(times), bool)
    for a, b in masked:
        keep &= ~((times >= a) & (times < b))
    return times[keep]


def match_events(pred: np.ndarray, true: np.ndarray, tol_s: float) -> List[Tuple[int, int, float]]:
    if len(pred) == 0 or len(true) == 0:
        return []
    err = pred[:, None] - true[None, :]
    feasible = np.abs(err) <= tol_s
    cost = np.where(feasible, np.abs(err), 1e6 + tol_s * (len(pred) + len(true)))
    r, c = linear_sum_assignment(cost)
    return [(int(i), int(j), float(err[i, j])) for i, j in zip(r, c) if feasible[i, j]]


def event_metrics(recordings: Sequence[Dict], tol_s: float) -> Dict:
    """recordings: [{'pred': times, 'true': times, 'masked': [(a, b), ...]}] for ONE event type."""
    tp = fp = fn = 0
    errs: List[float] = []
    for rec in recordings:
        pred = drop_masked(np.asarray(rec["pred"], float), rec.get("masked", []))
        true = np.asarray(rec["true"], float)
        m = match_events(pred, true, tol_s)
        tp += len(m)
        fp += len(pred) - len(m)
        fn += len(true) - len(m)
        errs += [e for _, _, e in m]
    P = tp / (tp + fp) if tp + fp else float("nan")
    R = tp / (tp + fn) if tp + fn else float("nan")
    F = 2 * P * R / (P + R) if tp and (P + R) > 0 else 0.0
    a = np.abs(np.asarray(errs))
    return {"tol_s": tol_s, "tp": tp, "fp": fp, "fn": fn, "precision": P, "recall": R, "f1": F,
            "abs_err_median_s": float(np.median(a)) if len(a) else None,
            "abs_err_p90_s": float(np.quantile(a, 0.9)) if len(a) else None,
            "signed_err_median_s": float(np.median(errs)) if errs else None}


def select_theta(val_recordings: Sequence[Dict], grid: Sequence[float] = THETA_GRID,
                 refractory_s: float = REFRACTORY_S, tol_s: float = 5.0,
                 precision_target: Optional[float] = 0.80, min_tp: int = 10) -> Dict:
    """theta on VAL: max recall among thetas with precision >= target (and >= min_tp hits), else max F1 ('weak')."""
    rows = []
    for th in grid:
        recs = [{"pred": extract_events(r["t"], r["p"], th, refractory_s), "true": r["true"],
                 "masked": r.get("masked", [])} for r in val_recordings]
        m = event_metrics(recs, tol_s)
        m["theta"] = float(th)
        rows.append(m)
    if not any(len(r["true"]) for r in val_recordings):
        return {"status": "abstain", "theta": 1.0, "reason": "no val events", "rows": rows}
    ok = [r for r in rows if r["tp"] >= min_tp and r["precision"] >= (precision_target or 0)]
    if precision_target is not None and ok:
        best = max(ok, key=lambda r: (r["recall"], -r["theta"]))
        return {"status": "strong", "theta": best["theta"], "evidence": best}
    best = max(rows, key=lambda r: (r["f1"], -r["theta"]))
    return {"status": "weak", "theta": best["theta"], "evidence": best}


__all__ = ["extract_events", "drop_masked", "match_events", "event_metrics", "select_theta", "REFRACTORY_S",
           "THETA_GRID"]
