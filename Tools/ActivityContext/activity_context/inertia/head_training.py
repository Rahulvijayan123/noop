"""Per-head training recipes: support -> weights -> fit -> calibrate on VAL -> operating points on VAL.

Each function returns ``(manifest head entry, heads.npz arrays, calibration.json entry, evidence)`` in the
exact shapes ``bundle.write_bundle`` validates. Predictions used for calibration/thresholds are computed
with the bundle's own numpy math (``heads.numpy_logits``), so what is fit is what the bundle will output.
"""

from __future__ import annotations

from typing import Dict, Mapping, Optional, Tuple

import numpy as np

from . import HEAD_CLASS_ORDERS
from . import abstention as A
from . import calibrate as Cal
from . import events as Ev
from . import metrics as M
from .assemble import Assembled, head_rows, is_wrist
from .heads import numpy_logits
from .targets import bits_to_matrix, resolve_support
from .train_heads import fit_grid, select_arch
from .weights import balance_rows, class_weights, event_pos_weights

MIN_WRIST_VAL = 20
FIT_CAP_TRAIN = 1000          # max Capture-24 windows per fine label used for FITTING (support uses all)
FIT_CAP_VAL = 500             # same for the early-stopping val loss (calibration/thresholds use all val)


def fit_rows(a: Assembled, rows: np.ndarray, cap: int, keep: np.ndarray = None) -> np.ndarray:
    """Compute cut (documented): Capture-24 rows are capped per fine label for fitting, keeping the windows
    with the smallest sha256(uid); other datasets and ``keep`` rows (e.g. event positives) are never capped."""
    import hashlib
    out = rows.copy()
    m = rows & (a.meta["dataset"].to_numpy() == "capture24")
    if keep is not None:
        m &= ~keep
    labels, uids = a.meta["label"].to_numpy(), a.meta["uid"].to_numpy()
    idx = np.flatnonzero(m)
    for lab in np.unique(labels[idx]):
        li = idx[labels[idx] == lab]
        if len(li) > cap:
            r = np.array([int(hashlib.sha256(u.encode()).hexdigest()[:12], 16) for u in uids[li]])
            out[li[np.argsort(r, kind="stable")[cap:]]] = False
    return out


def _bal(a: Assembled, rows: np.ndarray) -> np.ndarray:
    return balance_rows(a.meta["dataset"].to_numpy()[rows], a.meta["subject"].to_numpy()[rows])


def _probs_full(lg_full: np.ndarray, cal: Mapping, supported: np.ndarray) -> np.ndarray:
    p = np.zeros_like(lg_full)
    idx = np.flatnonzero(supported)
    c = dict(cal)
    for key in ("bias", "weight"):
        if c.get(key) is not None:
            c[key] = np.array([c[key][k] for k in idx], np.float64)
    p[:, idx] = Cal.apply_supported(lg_full[:, idx], c)
    return p


def train_class_head(h: str, tr: Assembled, va: Assembled, z_tr: np.ndarray, z_va: np.ndarray, families,
                     arch_mode: str, seed: int, val_sha: str) -> Optional[Tuple[Dict, Dict, Dict, Dict]]:
    order = list(HEAD_CLASS_ORDERS[h])
    K = len(order)
    rt, rv = head_rows(tr, h), head_rows(va, h)
    sup = resolve_support(h, tr.targets[h][rt], tr.meta["subject"].to_numpy()[rt], va.targets[h][rv],
                          va.meta["subject"].to_numpy()[rv], families)
    if not sup.supported.any():
        return None
    bt, bv = sup.resolve(tr.targets[h]), sup.resolve(va.targets[h])
    rv_all = bv != 0
    rt, rv = fit_rows(tr, bt != 0, FIT_CAP_TRAIN), fit_rows(va, rv_all, FIT_CAP_VAL)
    cw = class_weights(bt[rt], sup.supported)
    rw_t, rw_v = _bal(tr, rt), _bal(va, rv)
    common = dict(supported=sup.supported, class_weight=cw, rw_tr=rw_t, rw_va=rw_v, name=h)
    archs = ["linear", "mlp"] if arch_mode == "select" else [arch_mode]
    fits, grids = {}, {}
    for a in archs:
        fits[a], grids[a] = fit_grid("set", a, z_tr[rt], bt[rt].astype(np.int64), z_va[rv], bv[rv].astype(np.int64),
                                     K, seed=seed, **common)
    decision = {"chosen": arch_mode, "rule": "fixed by experiment"}
    if arch_mode == "select":
        zz = np.concatenate([z_tr[rt], z_va[rv]])
        bb = np.concatenate([bt[rt], bv[rv]]).astype(np.int64)
        subj = np.concatenate([tr.meta["subject"].to_numpy()[rt], va.meta["subject"].to_numpy()[rv]]).astype(str)
        uids = np.concatenate([tr.meta["uid"].to_numpy()[rt], va.meta["uid"].to_numpy()[rv]]).astype(str)
        ds = np.concatenate([tr.meta["dataset"].to_numpy()[rt], va.meta["dataset"].to_numpy()[rv]])
        decision = select_arch(h, zz, bb, subj, uids, sup.supported, cw, balance_rows(ds, subj), fits, seed)
    arch = decision["chosen"]
    fr = fits[arch]
    rv = rv_all                                   # calibration + operating points on ALL val windows
    lg = numpy_logits(fr.arrays, h, arch, z_va[rv])
    truth = bits_to_matrix(bv[rv], K)
    subj_v = va.meta["subject"].to_numpy()[rv].astype(str)
    cal = Cal.fit_softmax("val", lg, truth, subj_v, sup.supported, order, val_sha)
    p = _probs_full(lg, cal, sup.supported)
    wrist = is_wrist(va.meta)[rv]
    wrist_ok = all(truth[wrist, k].sum() >= MIN_WRIST_VAL for k in range(K) if sup.supported[k])
    pp, tt, ss = (p[wrist], truth[wrist], subj_v[wrist]) if wrist_ok else (p, truth, subj_v)
    ops = {c: A.select_operating_point(pp, tt, ss, k, bool(sup.supported[k])) for k, c in enumerate(order)}
    sup_c = [c for k, c in enumerate(order) if sup.supported[k]]
    status = {c: ops[c]["status"] for c in sup_c}
    merge = A.merge_partners(pp, tt, status, order)
    raw = _probs_full(lg, {"method": "temperature", "T": 1.0}, sup.supported)
    entry = {"arch": arch, "class_order": order, "supported": [bool(s) for s in sup.supported],
             "prior": {c: float(cal["class_prior"][c]) for c in sup_c}, "status": status,
             "tau": {c: float(ops[c]["tau"]) for c in sup_c}, "merge_into": merge, "covers": sup.covers,
             "support_counts": sup.counts, "selection": {"arch": {k: v for k, v in decision.items() if k != "per_fold"},
                                                       "grid": grids, "best_epoch": fr.best_epoch}}
    evidence = {"support": sup.to_dict(), "class_weights": dict(zip(order, cw.tolist())), "decision": decision,
                "operating_points": ops, "operating_point_set": "wrist-only val" if wrist_ok else "pooled val (flagged)",
                "val_raw": _brief(M.head_report(raw, truth, order, sup.supported, null_reps=50)),
                "val_calibrated": _brief(M.head_report(p, truth, order, sup.supported, null_reps=50))}
    return entry, fr.arrays, cal, evidence


def _brief(r: Dict) -> Dict:
    return {k: r.get(k) for k in ("n", "nll", "brier", "ece_top_equal_width_15", "balanced_accuracy",
                                  "macro_f1_present_supported", "accuracy")}


def train_transition_head(tr: Assembled, va: Assembled, z_tr, z_va, seed: int, val_sha: str,
                          min_windows: int = 200, min_subjects: int = 5, min_val_subjects: int = 2):
    order = list(HEAD_CLASS_ORDERS["transition"])
    yt, yv = tr.targets["transition"], va.targets["transition"]
    rt, rv = head_rows(tr, "transition"), head_rows(va, "transition")
    st, sv = tr.meta["subject"].to_numpy(), va.meta["subject"].to_numpy()
    counts, sup = {}, np.zeros(len(order), bool)
    for k, e in enumerate(order):
        pt, pv = yt[:, k] == 1, yv[:, k] == 1
        counts[e] = {"train_pos_windows": int(pt.sum()), "train_pos_subjects": int(len(np.unique(st[pt]))),
                     "train_neg_windows": int((yt[:, k] == 0).sum()), "val_pos_windows": int(pv.sum()),
                     "val_pos_subjects": int(len(np.unique(sv[pv])))}
        sup[k] = (counts[e]["train_pos_windows"] >= min_windows and counts[e]["train_pos_subjects"] >= min_subjects
                  and counts[e]["val_pos_subjects"] >= min_val_subjects)
    if not sup.any():
        return None, {"support_counts": counts, "note": "no event reaches the support threshold"}
    rv_all = rv
    rt = fit_rows(tr, rt, FIT_CAP_TRAIN, keep=(yt == 1).any(axis=1))
    rv = fit_rows(va, rv, FIT_CAP_VAL, keep=(yv == 1).any(axis=1))
    pw = event_pos_weights(yt[rt], sup)
    fr, grid = fit_grid("multilabel", "linear", z_tr[rt], yt[rt], z_va[rv], yv[rv], len(order), seed=seed,
                        supported=sup, class_weight=pw, rw_tr=_bal(tr, rt), rw_va=_bal(va, rv), name="transition")
    rv = rv_all
    lg = numpy_logits(fr.arrays, "transition", "linear", z_va[rv])
    cal = Cal.fit_per_event("val", lg, yv[rv], sup, order, val_sha)
    status, tau, ops = {}, {}, {}
    subj = sv[rv].astype(str)
    for k, e in enumerate(order):
        if not sup[k]:
            continue
        v = yv[rv][:, k] >= 0
        p = 1.0 / (1.0 + np.exp(-lg[v, k] / cal["T"][k]))
        probs2, truth2 = np.stack([1 - p, p], 1), np.stack([yv[rv][v, k] == 0, yv[rv][v, k] == 1], 1)
        ops[e] = A.select_operating_point(probs2, truth2, subj[v], 1, True)
        status[e], tau[e] = ops[e]["status"], float(ops[e]["tau"])
    theta = _event_theta(va, z_va, fr.arrays, cal, sup, order)
    entry = {"arch": "linear", "class_order": order, "supported": [bool(s) for s in sup], "prior": cal["class_prior"],
             "status": status, "tau": tau, "merge_into": {}, "covers": {}, "support_counts": counts,
             "selection": {"arch": "linear (fixed for the multi-label head)", "grid": {"linear": grid},
                           "event_theta": theta, "best_epoch": fr.best_epoch}}
    return (entry, fr.arrays, cal), {"support_counts": counts, "pos_weight": dict(zip(order, pw.tolist())),
                                     "operating_points": ops, "event_theta": theta}


def event_series(a: Assembled, z: np.ndarray, arrays, cal, sup, order, datasets=("opportunity", "pamap2", "hhar_watch")):
    """Dense (w30t) per-session event probability series + reference events (timing ground truth only)."""
    m = (a.meta["spec"].to_numpy() == "w30t") & a.meta["dataset"].isin(datasets).to_numpy()
    out = {}
    if not m.any():
        return out
    lg = numpy_logits(arrays, "transition", "linear", z[m])
    T = np.array([t if t is not None else 1.0 for t in cal["T"]])
    P = 1.0 / (1.0 + np.exp(-lg / T[None, :]))
    meta = a.meta[m]
    for sess, g in meta.groupby("session"):
        ii = np.flatnonzero((meta["session"] == sess).to_numpy())
        o = np.argsort(g["t0"].to_numpy(), kind="stable")
        ds = g["dataset"].iloc[0]
        ev = a.events.get(ds, {"events": [], "masked": []})
        out[sess] = {"t": (g["t0"].to_numpy()[o] + g["t1"].to_numpy()[o]) / 2, "P": P[ii][o], "dataset": ds,
                     "events": [e for e in ev["events"] if e["session"] == sess],
                     "masked": [(x[1], x[2]) for x in ev["masked"] if x[0] == sess]}
    return out


def _event_theta(va, z_va, arrays, cal, sup, order) -> Dict:
    series = event_series(va, z_va, arrays, cal, sup, order)
    res = {}
    for k, e in enumerate(order):
        if not sup[k]:
            continue
        recs = [{"t": s["t"], "p": s["P"][:, k], "true": np.array([x["t"] for x in s["events"] if x["type"] == e]),
                 "masked": s["masked"]} for s in series.values()]
        r = Ev.select_theta(recs) if recs else {"status": "abstain", "theta": 1.0, "reason": "no dense val series"}
        res[e] = {k2: v for k2, v in r.items() if k2 != "rows"}
    return res


def train_intensity_head(tr: Assembled, va: Assembled, z_tr, z_va, seed: int):
    rt, rv = head_rows(tr, "movement_intensity"), head_rows(va, "movement_intensity")
    if rt.sum() < 200 or rv.sum() < 20:
        return None, {"note": "too few MET-labelled windows"}
    yt, yv = tr.targets["movement_intensity"], va.targets["movement_intensity"]
    rv_all = rv
    rt, rv = fit_rows(tr, rt, FIT_CAP_TRAIN), fit_rows(va, rv, FIT_CAP_VAL)
    fr, grid = fit_grid("reg", "linear", z_tr[rt], yt[rt], z_va[rv], yv[rv], 1, seed=seed, rw_tr=_bal(tr, rt),
                        rw_va=_bal(va, rv), name="movement_intensity")
    rv = rv_all
    pred = 1.0 / (1.0 + np.exp(-numpy_logits(fr.arrays, "movement_intensity", "linear", z_va[rv])[:, 0]))
    res = np.abs(pred - yv[rv])
    n = len(res)
    q = float(np.quantile(res, min(1.0, np.ceil((n + 1) * 0.8) / n), method="higher"))
    entry = {"arch": "linear", "output": "sigmoid", "interval80": q, "target": "clip(ln(MET)/ln(12),0,1)",
             "selection": {"grid": {"linear": grid}, "best_epoch": fr.best_epoch,
                           "interval80_rule": "split-conformal |pred - y| quantile ceil((n+1)0.8)/n on val",
                           "val_mae": float(res.mean()), "n_val": int(n)}}
    return (entry, fr.arrays), {"val_mae": float(res.mean()), "interval80": q,
                                "datasets": sorted(tr.meta["dataset"][rt].unique().tolist())}


__all__ = ["train_class_head", "train_transition_head", "train_intensity_head", "event_series"]
