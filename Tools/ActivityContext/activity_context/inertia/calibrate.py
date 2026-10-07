"""Post-hoc calibration on VALIDATION logits only (ported from Agent E, set-aware; spec §14).

Softmax heads (on the supported-class logits; unsupported classes are -inf and carry no parameter):
  ``temperature`` z/T  |  ``temp_bias`` z/T + b  |  ``vector`` w*z + b  (Guo et al. 2017)
T is found by a bounded 1-D search on log T in [log 0.05, log 20] (convex in 1/T; a solution at a bound is
flagged). Selection — subject-grouped 5-fold CV *inside val*: a richer method replaces ``temperature`` only
if its CV-NLL is >= 1% lower and its CV classwise-ECE is not worse by > 0.005, and only when every
supported class has >= 20 val windows; the chosen method is refit on all of val.
Multi-label ``transition``: ``temperature_per_event`` — one T per supported event on its valid val entries.
Set truth: NLL = -log sum_{k in S} p_k (gradient p - p|S).

The output dicts are exactly the ``calibration.json`` head entries of ``bundle.write_bundle``; ``fit.split``
is always ``"val"`` and :func:`fit_softmax` refuses any other split name.
"""

from __future__ import annotations

import hashlib
from typing import Any, Dict, List, Optional, Sequence

import numpy as np
from scipy.optimize import minimize, minimize_scalar
from scipy.special import logsumexp

from . import metrics as M

LOG_T_BOUNDS = (float(np.log(0.05)), float(np.log(20.0)))
METHODS = ("temperature", "temp_bias", "vector")


class CalibrationLeak(RuntimeError):
    pass


def _set_nll(z: np.ndarray, truth: np.ndarray) -> float:
    return float(np.mean(logsumexp(z, axis=1) - logsumexp(np.where(truth, z, -np.inf), axis=1)))


def fit_temperature(z: np.ndarray, truth: np.ndarray) -> Dict[str, Any]:
    """z: supported-class logits [N, Ks]; truth bool [N, Ks]."""
    r = minimize_scalar(lambda lt: _set_nll(z / np.exp(lt), truth), bounds=LOG_T_BOUNDS, method="bounded",
                        options={"xatol": 1e-6, "maxiter": 500})
    T = float(np.exp(r.x))
    at_bound = bool(min(abs(r.x - LOG_T_BOUNDS[0]), abs(r.x - LOG_T_BOUNDS[1])) < 1e-3)
    return {"T": T, "at_bound": at_bound}


def _fit_affine(z: np.ndarray, truth: np.ndarray, T0: float, vector: bool, l2: float = 1e-3) -> Dict[str, Any]:
    N, Ks = z.shape
    w0 = np.full(Ks, 1.0 / T0)

    def unpack(theta):
        return (theta[:Ks], theta[Ks:]) if vector else (w0, theta)

    def f(theta):
        w, b = unpack(theta)
        lg = z * w[None, :] + b[None, :]
        lse = logsumexp(lg, axis=1)
        lse_s = logsumexp(np.where(truth, lg, -np.inf), axis=1)
        loss = float(np.mean(lse - lse_s)) + l2 * float(np.sum(b ** 2))
        p = np.exp(lg - lse[:, None])
        q = np.where(truth, np.exp(lg - lse_s[:, None]), 0.0)
        g = (p - q) / N
        gb = g.sum(axis=0) + 2 * l2 * b
        if vector:
            loss += l2 * float(np.sum((w - w0) ** 2))
            return loss, np.concatenate([(g * z).sum(axis=0) + 2 * l2 * (w - w0), gb])
        return loss, gb

    theta0 = np.concatenate([w0, np.zeros(Ks)]) if vector else np.zeros(Ks)
    r = minimize(f, theta0, jac=True, method="L-BFGS-B", options={"maxiter": 2000, "gtol": 1e-9})
    w, b = unpack(r.x)
    b = b - b.mean()                               # gauge: softmax is shift-invariant
    return {"weight": w, "bias": b, "converged": bool(r.success)}


def _make(method: str, z: np.ndarray, truth: np.ndarray) -> Dict[str, Any]:
    t = fit_temperature(z, truth)
    out = {"method": method, "T": t["T"], "T_at_bound": t["at_bound"]}
    if method in ("temp_bias", "vector"):
        a = _fit_affine(z, truth, t["T"], vector=method == "vector")
        out["bias"] = a["bias"]
        out["converged"] = a["converged"]
        if method == "vector":
            out["weight"] = np.maximum(a["weight"], 1e-6)
    return out


def apply_supported(z: np.ndarray, cal: Dict[str, Any]) -> np.ndarray:
    """Calibrated probabilities over the supported columns (same math as bundle_math.calibrate)."""
    m = cal["method"]
    if m == "temperature":
        lg = z / cal["T"]
    elif m == "temp_bias":
        lg = z / cal["T"] + cal["bias"][None, :]
    else:
        lg = z * cal["weight"][None, :] + cal["bias"][None, :]
    lg = lg - lg.max(axis=1, keepdims=True)
    e = np.exp(lg)
    return e / e.sum(axis=1, keepdims=True)


def _folds(groups: np.ndarray, n_folds: int) -> List[np.ndarray]:
    subj = np.unique(groups)
    n_folds = min(n_folds, len(subj))
    return [np.isin(groups, subj[i::n_folds]) for i in range(n_folds)]


def fit_softmax(split_name: str, logits_full: np.ndarray, truth_full: np.ndarray, subjects: np.ndarray,
                support_mask: np.ndarray, class_order: Sequence[str], val_split_sha256: str,
                min_rel_gain: float = 0.01, max_cw_ece_worsening: float = 0.005, min_class_val: int = 20,
                n_folds: int = 5) -> Dict[str, Any]:
    """Select + fit a softmax-head calibrator on VAL; returns the calibration.json head entry."""
    if split_name != "val":
        raise CalibrationLeak(f"calibration may only be fit on the validation split, got {split_name!r}")
    sup = np.asarray(support_mask, bool)
    idx = np.flatnonzero(sup)
    keep = truth_full[:, idx].any(axis=1)
    z, truth, g = logits_full[keep][:, idx], truth_full[keep][:, idx], np.asarray(subjects)[keep]
    counts = truth.sum(axis=0)
    eligible = ["temperature"] + (["temp_bias", "vector"] if (counts >= min_class_val).all() else [])
    cv: Dict[str, Dict[str, float]] = {}
    folds = _folds(g, n_folds)
    for m in eligible:
        nl = cw = n = 0.0
        for te in folds:
            if te.all() or not te.any():
                continue
            c = _make(m, z[~te], truth[~te])
            p = apply_supported(z[te], c)
            y_att, _ = M.attributed_truth(p, truth[te])
            nl += M.nll(p, truth[te]) * te.sum()
            cw += M.classwise_ece(p, y_att, np.ones(len(idx), bool))[0] * te.sum()
            n += te.sum()
        if n:
            cv[m] = {"cv_nll": nl / n, "cv_classwise_ece": cw / n}
    chosen = "temperature"
    for m in ("temp_bias", "vector"):
        if m in cv and "temperature" in cv:
            gain = (cv[chosen]["cv_nll"] - cv[m]["cv_nll"]) / max(cv[chosen]["cv_nll"], 1e-12)
            if gain >= min_rel_gain and cv[m]["cv_classwise_ece"] <= cv["temperature"]["cv_classwise_ece"] + max_cw_ece_worsening:
                chosen = m
    c = _make(chosen, z, truth)
    p = apply_supported(z, c)
    prior = p.mean(axis=0)
    K = len(class_order)

    def full(v):
        out: List[Optional[float]] = [None] * K
        for j, k in enumerate(idx):
            out[k] = float(v[j])
        return out

    entry: Dict[str, Any] = {"method": chosen, "class_order": list(class_order), "support_mask": [bool(s) for s in sup],
                             "class_prior": {class_order[k]: float(prior[j]) for j, k in enumerate(idx)}}
    if chosen in ("temperature", "temp_bias"):
        entry["T"] = float(c["T"])
    if chosen in ("temp_bias", "vector"):
        entry["bias"] = full(c["bias"])
    if chosen == "vector":
        entry["weight"] = full(c["weight"])
    freq = counts / max(counts.sum(), 1)
    entry["fit"] = {"split": "val", "n": int(len(z)), "n_subjects": int(len(np.unique(g))),
                    "n_dropped_unsupported_truth": int((~keep).sum()), "val_split_sha256": val_split_sha256,
                    "val_logits_sha256": hashlib.sha256(np.ascontiguousarray(logits_full, np.float64).tobytes()).hexdigest(),
                    "T_at_bound": bool(c.get("T_at_bound", False)),
                    "calibration_in_the_large_max_abs": float(np.max(np.abs(prior - freq)))}
    entry["selection"] = {"eligible": eligible, "cv": cv, "chosen": chosen, "n_folds": len(folds),
                          "rule": f"richer method iff relative CV-NLL gain >= {min_rel_gain} and CV classwise-ECE "
                                  f"worsening <= {max_cw_ece_worsening}; needs >= {min_class_val} val windows per class"}
    return entry


def fit_per_event(split_name: str, logits: np.ndarray, targets: np.ndarray, supported: np.ndarray,
                  class_order: Sequence[str], val_split_sha256: str) -> Dict[str, Any]:
    """``temperature_per_event`` for the multi-label transition head (binary NLL per event on val)."""
    if split_name != "val":
        raise CalibrationLeak(f"calibration may only be fit on the validation split, got {split_name!r}")
    K = len(class_order)
    T: List[Optional[float]] = [None] * K
    prior: Dict[str, float] = {}
    info: Dict[str, Any] = {}
    for k in range(K):
        if not supported[k]:
            continue
        v = targets[:, k] >= 0
        z, y = logits[v, k], targets[v, k].astype(np.float64)
        if not v.any() or y.min() == y.max():
            T[k] = 1.0
            info[class_order[k]] = {"n": int(v.sum()), "note": "single-class val: T=1"}
        else:
            def f(lt):
                s = z / np.exp(lt)
                return float(np.mean(np.logaddexp(0.0, s) - y * s))
            r = minimize_scalar(f, bounds=LOG_T_BOUNDS, method="bounded", options={"xatol": 1e-6, "maxiter": 500})
            T[k] = float(np.exp(r.x))
            info[class_order[k]] = {"n": int(v.sum()), "n_pos": int(y.sum()),
                                    "at_bound": bool(min(abs(r.x - LOG_T_BOUNDS[0]), abs(r.x - LOG_T_BOUNDS[1])) < 1e-3)}
        p = 1.0 / (1.0 + np.exp(-logits[v, k] / T[k])) if v.any() else np.array([0.0])
        prior[class_order[k]] = float(np.mean(p))
    return {"method": "temperature_per_event", "class_order": list(class_order),
            "support_mask": [bool(s) for s in supported], "T": T, "class_prior": prior,
            "fit": {"split": "val", "val_split_sha256": val_split_sha256, "per_event": info}}


__all__ = ["fit_softmax", "fit_per_event", "fit_temperature", "apply_supported", "CalibrationLeak", "METHODS",
           "LOG_T_BOUNDS"]
