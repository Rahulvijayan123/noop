"""Test-time evaluation parts: transition events, movement intensity, OOD benchmark, prediction export.

All inputs are the arrays produced from ``HeadBundle.apply`` rows (see ``evaluate_heads.rows_to_arrays``).
The OOD benchmark compares methods by refitting the deterministic OOD reference on TRAIN (exactly as the
bundle was built; the refit is checked against the bundle's own arrays) and uses the VAL thresholds stored in
``ood_reference.json`` — nothing is fit on test.
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict

import numpy as np

from . import HEAD_CLASS_ORDERS
from . import abstention as A
from . import events as Ev
from . import metrics as M
from . import ood as O
from .assemble import activity_keys, any_target, assemble
from .experiments import HELDOUT_DATASET_OOD

TIMING_DATASETS = ("opportunity", "pamap2", "hhar_watch")


def eval_transition(bundle, out, test, raw_logits) -> Dict[str, Any]:
    meta = bundle.manifest["heads"]["transition"]
    order = list(HEAD_CLASS_ORDERS["transition"])
    P, Y = out["transition"], test.targets["transition"]
    T = bundle.calibration["heads"]["transition"]["T"]
    ds = test.meta["dataset"].to_numpy()
    rep: Dict[str, Any] = {"per_event": {}, "event_level": {}}
    for k, e in enumerate(order):
        if not meta["supported"][k]:
            rep["per_event"][e] = {"supported": False, "n_pos": int((Y[:, k] == 1).sum())}
            continue
        v = (Y[:, k] >= 0) & out["valid"]
        p, y = P[v, k], Y[v, k] == 1
        raw = 1.0 / (1.0 + np.exp(-raw_logits["transition"][v, k]))
        r = {"supported": True, "n": int(v.sum()), "n_pos": int(y.sum()), "auroc": M.binary_auc(p[~y], p[y]),
             "average_precision": M.average_precision(p[~y], p[y]), "prevalence": float(y.mean()) if len(y) else None,
             "brier": float(np.mean((p - y) ** 2)), "ece_15": M.ece_binary(p, y),
             "uncalibrated": {"brier": float(np.mean((raw - y) ** 2)), "ece_15": M.ece_binary(raw, y)}, "T": T[k],
             "per_dataset": {d: {"n_pos": int(y[ds[v] == d].sum()), "auroc": M.binary_auc(p[(ds[v] == d) & ~y], p[(ds[v] == d) & y])}
                             for d in sorted(np.unique(ds[v]))}}
        vs = meta["status"][e]
        if vs in ("strong", "weak"):
            P2, T2, tau = np.stack([1 - p, p], 1), np.stack([~y, y], 1), float(meta["tau"][e])
            g = A.check_gate(P2, T2, 1, tau)
            dv = ds[v]
            per = {d: A.check_gate(P2[dv == d], T2[dv == d], 1, tau, dataset_level=True) for d in sorted(np.unique(dv))}
            final, reasons = A.final_status(vs, g, per)
            r["gate"] = {"val_status": vs, "test": g, "per_dataset": per, "final_status": final, "reasons": reasons}
        else:
            r["gate"] = {"val_status": vs, "test": None, "per_dataset": {}, "final_status": vs, "reasons": []}
        rep["per_event"][e] = r
    rep["event_level"] = _event_level(bundle, out, test, meta, order)
    rep["note"] = ("event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s "
                   "windows); Capture-24 supports event presence only (per-window AUROC/AP above)")
    return rep


def _event_level(bundle, out, test, meta, order) -> Dict[str, Any]:
    m = (test.meta["spec"].to_numpy() == "w30t") & test.meta["dataset"].isin(TIMING_DATASETS).to_numpy() & out["valid"]
    sel = meta.get("selection", {}).get("event_theta", {})
    res: Dict[str, Any] = {}
    if not m.any():
        return {"note": "no dense test series"}
    mt = test.meta[m].reset_index(drop=True)
    P = out["transition"][m]
    series = []
    for sess, g in mt.groupby("session"):
        o = g.sort_values("t0").index.to_numpy()
        ev = test.events.get(g["dataset"].iloc[0], {"events": [], "masked": []})
        series.append({"t": ((mt["t0"] + mt["t1"]) / 2).to_numpy()[o], "P": P[o],
                       "events": [x for x in ev["events"] if x["session"] == sess],
                       "masked": [(x[1], x[2]) for x in ev["masked"] if x[0] == sess]})
    for k, e in enumerate(order):
        if not meta["supported"][k]:
            continue
        n_true = sum(1 for s in series for x in s["events"] if x["type"] == e)
        theta = float(sel.get(e, {}).get("theta", 0.5))
        r = {"theta_from_val": theta, "theta_status": sel.get(e, {}).get("status"), "n_true_events": n_true}
        for tol in (5.0, 10.0):
            recs = [{"pred": Ev.extract_events(s["t"], s["P"][:, k], theta), "true":
                     np.array([x["t"] for x in s["events"] if x["type"] == e]), "masked": s["masked"]} for s in series]
            r[f"tol_{int(tol)}s"] = Ev.event_metrics(recs, tol)
        res[e] = r
    return res


def eval_intensity(bundle, out, test) -> Dict[str, Any]:
    from scipy.stats import spearmanr
    pred, y = out["movement_intensity"], test.targets["movement_intensity"]
    q = float(bundle.manifest["heads"]["movement_intensity"]["interval80"])
    ds = test.meta["dataset"].to_numpy()
    v = np.isfinite(y) & np.isfinite(pred)

    def rep(mask):
        p, t = pred[mask], y[mask]
        if len(t) < 3:
            return {"n": int(len(t))}
        ss = float(((t - t.mean()) ** 2).sum())
        return {"n": int(len(t)), "mae": float(np.abs(p - t).mean()), "r2": 1 - float(((p - t) ** 2).sum()) / ss if ss > 0 else None,
                "spearman": float(spearmanr(p, t).statistic), "interval80_coverage": float((np.abs(p - t) <= q).mean()),
                "mae_constant_test_mean": float(np.abs(t - t.mean()).mean())}

    return {"interval80": q, "pooled": rep(v), "per_dataset": {d: rep(v & (ds == d)) for d in sorted(np.unique(ds[v]))},
            "target": "clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV "
                      "measured COSMED METs per window (gotov-met-1)"}


def _refit(exp, cw, cache_root):
    tr = assemble(exp.encoder, [exp.window], exp.datasets, cw, exp.ood_holdout, exp.train_datasets, ("train",),
                  cache_root)
    idt = any_target(tr)
    return O.OODModel(tr.emb[idt], activity_keys(tr.meta[idt]), tr.meta["uid"].to_numpy()[idt])


def eval_ood(exp, bundle, out, test, daph, cw, cache_root) -> Dict[str, Any]:
    om = bundle.ood_meta
    cls = test.meta["kind"].to_numpy() == "cls"
    held = np.zeros(len(test.meta), bool)
    for d in test.meta["dataset"].unique():
        lab = set(cw.ood_holdout(d))
        if lab:
            held |= ((test.meta["dataset"] == d) & test.meta["label"].isin(lab) & test.meta["pure"]).to_numpy()
    idm = cls & any_target(test) & out["valid"] & (~held if exp.ood_holdout else True)
    rep: Dict[str, Any] = {"bundle_method": om["method"], "threshold": om["threshold"], "k": om.get("k"),
                           "id_test_false_alarm_rate": float(np.mean(out["ood_score"][idm] > om["threshold"])),
                           "n_id_test": int(idm.sum())}
    loc = test.targets["locomotion"]
    heldout_ds = HELDOUT_DATASET_OOD.get(exp.name)
    if not (exp.role == "ood_bench" or heldout_ds) or daph is None or not len(daph.meta):
        return rep
    model = _refit(exp, cw, cache_root)
    arr = bundle.ood_arrays
    if om["method"] in ("maha_min", "maha_global", "knn"):
        ref = model.arrays(om["method"])
        rep["refit_matches_bundle"] = all(np.array_equal(np.asarray(ref[k], arr[k].dtype), arr[k]) for k in arr)
    sup = np.array(bundle.manifest["heads"]["locomotion"]["supported"], bool)
    from .bundle_math import standardize
    z_t = standardize(test.emb, bundle.heads_arrays["std.mu"], bundle.heads_arrays["std.sigma"])
    z_d = standardize(daph.emb, bundle.heads_arrays["std.mu"], bundle.heads_arrays["std.sigma"])
    meta_l = bundle.manifest["heads"]["locomotion"]
    from .heads import numpy_logits
    raw_t = numpy_logits(bundle.heads_arrays, "locomotion", meta_l["arch"], z_t)[:, sup]
    raw_d = numpy_logits(bundle.heads_arrays, "locomotion", meta_l["arch"], z_d)[:, sup]
    sets = {"heldout_activities_test": held & out["valid"], "daphnet_fog_nonwrist": None}
    if heldout_ds:                            # held-out DATASET (never trained on): its test windows are the OOD set
        short = heldout_ds.replace("_watch", "")
        sets = {f"heldout_dataset_{short}_test": (test.meta["dataset"] == heldout_ds).to_numpy() & cls & out["valid"],
                "daphnet_fog_nonwrist": None}
        idm = idm & (test.meta["dataset"] != heldout_ds).to_numpy()
    rep["benchmark"] = {}
    for name, mask in sets.items():
        if mask is not None and not mask.any():
            continue
        r = {}
        for meth, thr in om["thresholds"].items():
            base, k = (meth.split("@")[0], int(meth.split("@")[1])) if "@" in meth else (meth, 10)

            def score(emb, raw):
                return model.score(base, emb, raw, k=k)

            s_id = score(test.emb[idm], raw_t[idm])
            s_ood = score(daph.emb, raw_d) if mask is None else score(test.emb[mask], raw_t[mask])
            r[meth] = O.ood_report(s_id, s_ood, float(thr))
        rep["benchmark"][name] = r
        if mask is not None and "locomotion" in bundle.manifest["heads"]:
            pool = idm | mask
            P = out["locomotion"][pool]
            truth = ((loc[pool].astype(np.int64)[:, None] >> np.arange(P.shape[1])) & 1).astype(bool)
            correct = truth[np.arange(len(P)), P.argmax(1)] & idm[pool]
            conf = P.max(1)
            rep["benchmark"][name]["combined_risk_coverage_locomotion"] = {
                "confidence_only": A.combined_risk_coverage(conf, correct, out["ood_score"][pool], None),
                "with_ood_rejection": A.combined_risk_coverage(conf, correct, out["ood_score"][pool], om["threshold"]),
                "note": "pool = ID test windows + OOD windows; OOD windows count as errors; bundle OOD method"}
    rep["selection_on_val"] = bundle.manifest["training"].get("ood_selection")
    return rep


def save_predictions(bundle, out, arr, test, out_dir) -> Dict[str, Any]:
    os.makedirs(out_dir, exist_ok=True)
    files = {}
    for d in ("wisdm2019_watch", "capture24"):
        m = (test.meta["dataset"] == d).to_numpy() & (test.meta["kind"] == "cls").to_numpy()
        if not m.any():
            continue
        mt = test.meta[m]
        z: Dict[str, Any] = {k: mt[k].to_numpy().astype(str if k in ("uid", "subject", "session", "label") else float)
                             for k in ("uid", "subject", "session", "label", "t0", "t1", "purity")}
        for h in bundle.heads_present():
            p = out[h][m].copy()
            p[:, ~np.array(bundle.manifest["heads"][h]["supported"], bool)] = np.nan
            z[f"probs_{h}"] = p
            z[f"raw_logits_{h}"] = arr.raw_logits[h][m]
        z["movement_intensity"] = out["movement_intensity"][m]
        z["ood_score"], z["is_ood"], z["valid"] = out["ood_score"][m], out["is_ood"][m], out["valid"][m]
        z["class_orders_json"] = np.asarray(json.dumps({h: list(HEAD_CLASS_ORDERS[h]) for h in bundle.heads_present()}))
        z["bundle_sha256"] = np.asarray(bundle.bundle_sha256)
        path = os.path.join(out_dir, f"{d}.npz")
        np.savez_compressed(path, **z)
        files[d] = {"path": os.path.join("research/inertia-bundles", bundle.bundle_id, "test_predictions", f"{d}.npz"),
                    "n_windows": int(m.sum()), "subjects": sorted(mt["subject"].unique().tolist())}
    files["format"] = ("npz per dataset: uid/subject/session/label (str), t0/t1 (float s, dataset clock: Capture-24 unix "
                       "s, WISDM device ns/1e9), purity; probs_<head> [N,K] over the fixed class order (NaN = "
                       "unsupported), raw_logits_<head> (-inf unsupported), movement_intensity, ood_score, is_ood, valid, "
                       "class_orders_json, bundle_sha256. Join HART windows on (subject, session, t0..t1).")
    return files


__all__ = ["eval_transition", "eval_intensity", "eval_ood", "save_predictions"]
