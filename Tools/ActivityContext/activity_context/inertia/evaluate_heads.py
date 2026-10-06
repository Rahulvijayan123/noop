"""Evaluate ONE frozen bundle ONCE on the held-out test subjects — through ``load_bundle(...).apply(...)``.

    python -m activity_context.inertia.evaluate_heads --experiment primary-hc
    (= python -m activity_context.inertia.pipeline_cli evaluate --experiment primary-hc)

The test windows are materialised only here, wrapped in a :class:`~.integrity.TestVault`; the bundle is
hash-stamped and the ledger (``eval/inertia/test_ledger.jsonl``) refuses undeclared experiments and silent
re-evaluations. Every number comes from the production inference path (``HeadBundle.apply`` -> per-window
dicts); calibration provenance (fit on val, val hash != test hash) and the head input list are asserted
before the vault opens. Per head: pooled, per dataset and wrist-only metrics with subject-cluster
bootstrap CIs, every class listed, the one-shot test gate per class. Results:
``eval/inertia/<bundle_id>/evaluation.{json,md}`` (copied, unlisted, into the bundle directory).
"""

from __future__ import annotations

import json
import os
import shutil
from typing import Any, Dict, Optional

import numpy as np

from . import HEAD_CLASS_ORDERS
from . import abstention as A
from . import metrics as M
from .assemble import any_target, assemble, is_wrist
from .bootstrap import cluster_bootstrap
from .bundle import BundleError, load_bundle
from .cache import CACHE_ROOT, CacheError
from .contract import InertiaUnavailable
from .eval_parts import eval_intensity, eval_ood, eval_transition, save_predictions
from .experiments import BUNDLES_ROOT, DECLARED, EVAL_ROOT, WRIST, Experiment, get_experiment
from .integrity import TestVault, array_sha256, assert_calibration_provenance, assert_head_inputs
from .mappings import load_mappings
from .targets import CLASS_HEADS, Support, bits_to_matrix

N_BOOT = 200


APPLY_CHUNK = 1024


def apply_chunked(bundle, emb: np.ndarray, chunk: int = APPLY_CHUNK):
    """``HeadBundle.apply`` in row chunks (the bundle's Mahalanobis OOD score materialises [B, C, D]; serve
    requests are small, a 100k-window evaluation is not). Row-wise math, so chunking changes nothing.
    Raw (uncalibrated) logits for the before/after-calibration comparison come from the same
    ``bundle_math`` head functions (no second OOD pass)."""
    from types import SimpleNamespace
    from .heads import numpy_logits
    from .bundle_math import standardize
    rows: list = []
    raw = {h: [] for h in bundle.heads_present()}
    for i in range(0, len(emb), chunk):
        e = emb[i:i + chunk]
        rows += bundle.apply(e)
        z = standardize(np.where(np.isfinite(e), e, 0.0), bundle.heads_arrays["std.mu"], bundle.heads_arrays["std.sigma"])
        for h in raw:
            meta = bundle.manifest["heads"][h]
            lg = numpy_logits(bundle.heads_arrays, h, meta["arch"], z)
            lg[:, ~np.array(meta["supported"], bool)] = -np.inf
            raw[h].append(lg)
    return rows, SimpleNamespace(raw_logits={h: np.concatenate(v) for h, v in raw.items()})


def rows_to_arrays(bundle, rows, n: int) -> Dict[str, Any]:
    """Per-window dicts from HeadBundle.apply -> full-class-order arrays (unsupported / omitted = 0 / NaN)."""
    out: Dict[str, Any] = {"valid": np.array([not r.get("nonfinite") for r in rows], bool)}
    for h in bundle.heads_present():
        order = HEAD_CLASS_ORDERS[h]
        P = np.zeros((n, len(order))) if h != "transition" else np.full((n, len(order)), np.nan)
        for i, r in enumerate(rows):
            for c, v in r.get(h, {}).items():
                P[i, order.index(c)] = v
        out[h] = P
    out["movement_intensity"] = np.array([r.get("movement_intensity", np.nan) for r in rows], float)
    out["ood_score"] = np.array([r.get("ood_score", np.nan) for r in rows], float)
    out["is_ood"] = np.array([bool(r.get("is_ood", False)) for r in rows])
    return out


def support_from_manifest(h: str, meta) -> Support:
    return Support(h, list(meta["class_order"]), np.array(meta["supported"], bool), dict(meta.get("covers", {})))


def _bootstrap(probs, truth, subj, strata, sup) -> Dict[str, Any]:
    def mf1(idx):
        y, _ = M.attributed_truth(probs[idx], truth[idx])
        cm = M.confusion(y, probs[idx].argmax(1), probs.shape[1])
        return M.macro_f1(cm, [k for k in range(len(sup)) if sup[k] and cm[k].sum() > 0])

    def bacc(idx):
        y, _ = M.attributed_truth(probs[idx], truth[idx])
        return M.balanced_accuracy(M.confusion(y, probs[idx].argmax(1), probs.shape[1]))

    return {"macro_f1": cluster_bootstrap(mf1, subj, strata, N_BOOT), "balanced_accuracy": cluster_bootstrap(bacc, subj, strata, N_BOOT),
            "nll": cluster_bootstrap(lambda i: M.nll(probs[i], truth[i]), subj, strata, N_BOOT)}


def eval_class_head(h: str, bundle, out: Dict, test, raw_logits) -> Dict[str, Any]:
    meta = bundle.manifest["heads"][h]
    sup = support_from_manifest(h, meta)
    order = list(HEAD_CLASS_ORDERS[h])
    K = len(order)
    bits = test.targets[h]
    rb = sup.resolve(bits)
    unsup = {}
    lost = (bits != 0) & (rb == 0)
    for k, c in enumerate(order):
        unsup[c] = int((lost & ((bits.astype(np.int64) >> k) & 1 == 1)).sum())
    m = (rb != 0) & out["valid"]
    P, truth = out[h][m], bits_to_matrix(rb[m], K)
    meta_t = test.meta[m]
    subj, ds = meta_t["subject"].to_numpy().astype(str), meta_t["dataset"].to_numpy().astype(str)
    rep: Dict[str, Any] = {"pooled": M.head_report(P, truth, order, sup.supported, unsupported_truth_counts=unsup)}
    idx = np.flatnonzero(sup.supported)
    lg = raw_logits[h][m][:, idx]
    raw = np.zeros_like(P)
    e = np.exp(lg - lg.max(axis=1, keepdims=True))
    raw[:, idx] = e / e.sum(axis=1, keepdims=True)
    rr = M.head_report(raw, truth, order, sup.supported, null_reps=50)
    rep["uncalibrated_softmax"] = {k: rr[k] for k in ("nll", "brier", "ece_top_equal_width_15", "classwise_ece_equal_width_15")}
    rep["bootstrap_ci"] = _bootstrap(P, truth, subj, ds, sup.supported)
    rep["per_dataset"] = {}
    for d in sorted(np.unique(ds)):
        dm = ds == d
        r = M.head_report(P[dm], truth[dm], order, sup.supported, null_reps=50)
        r["bootstrap_macro_f1"] = _bootstrap(P[dm], truth[dm], subj[dm], None, sup.supported)["macro_f1"]
        rep["per_dataset"][d] = r
    w = is_wrist(meta_t)
    rep["wrist_only"] = {"n": int(w.sum()), "note": "every training/test placement is wrist or forearm; equals pooled"
                         if w.all() else "subset", "macro_f1": M.head_report(P[w], truth[w], order, sup.supported,
                                                                               null_reps=20).get("macro_f1_present_supported")}
    conf = P.max(axis=1)
    correct = truth[np.arange(len(P)), P.argmax(axis=1)]
    rep["fixed_thresholds"] = A.at_fixed_thresholds(P, truth)
    rep["risk_coverage"] = A.risk_coverage(conf, correct)
    rep["aurc"] = A.aurc(conf, correct)
    gate = {}
    for k, c in enumerate(order):
        if not sup.supported[k]:
            continue
        vs = meta["status"][c]
        g = A.check_gate(P, truth, k, float(meta["tau"][c])) if vs in ("strong", "weak") else None
        gate[c] = {"val_status": vs, "tau": meta["tau"][c], "test": g, "final_status": A.apply_gate(vs, g)}
    rep["gate"] = gate
    counts = {c: meta["support_counts"][c]["train_windows"] for c in order}
    maj = int(np.argmax([counts[c] if sup.supported[k] else -1 for k, c in enumerate(order)]))
    yhat = np.full(len(P), maj)
    y_att = np.where(truth[:, maj], maj, truth.argmax(axis=1))
    cm = M.confusion(y_att, yhat, K)
    rep["majority_baseline"] = {"class": order[maj], "accuracy": float(truth[:, maj].mean()),
                                "macro_f1": M.macro_f1(cm, [k for k in range(K) if sup.supported[k] and cm[k].sum() > 0]),
                                "balanced_accuracy": M.balanced_accuracy(cm)}
    return rep


def evaluate_experiment(exp: Experiment, cache_root: str = CACHE_ROOT, bundles_root: str = BUNDLES_ROOT,
                        eval_root: str = EVAL_ROOT, rerun_reason: Optional[str] = None) -> Dict[str, Any]:
    if exp.encoder.startswith("inertia-1/"):
        raise InertiaUnavailable("model_missing", "blocked: no checkpoint — real Inertia-1 evaluation is blocked")
    bdir = os.path.join(bundles_root, exp.bundle_id)
    bundle = load_bundle(bdir)
    man = bundle.manifest
    if man["training"]["experiment"] != exp.name or man["encoder"]["encoder_id"] != exp.encoder:
        raise BundleError("config_mismatch", f"{bdir} was not produced by experiment {exp.name}")
    assert_head_inputs(man["training"]["head_inputs"])
    cw = load_mappings()
    if cw.sha256 != man["label_mappings_sha256"]:
        raise BundleError("config_mismatch", "label_mappings.json changed since the bundle was trained")
    specs = [exp.window] + ([exp.trn_window] if exp.trn_window else [])
    test = assemble(exp.encoder, specs, WRIST, cw, False, None, ("test",), cache_root)
    try:
        extra = assemble(exp.encoder, [exp.window], ("daphnet_fog",), cw, False, None, ("ood",), cache_root)
    except CacheError:
        extra = None                                   # Daphnet is windowed for w30 only (OOD probe)
    vault = TestVault({"test": test, "daphnet": extra}, [test.meta["uid"].to_numpy(), test.meta["subject"].to_numpy()],
                      os.path.join(eval_root, "test_ledger.jsonl"))
    assert_calibration_provenance(bundle.calibration, vault.test_sha256)

    def evaluator(payload):
        t = payload["test"]
        from .build_bundle import log
        log(f"{exp.name}: apply bundle to {len(t.meta)} test windows")
        rows, arr = apply_chunked(bundle, t.emb)         # production inference path (HeadBundle.apply)
        out = rows_to_arrays(bundle, rows, len(t.meta))
        from .smoke import training_side_probs
        side = training_side_probs(bundle.path, t.emb[:2000])
        parity = max(float(np.abs(out[h][:2000][:, [k for k, s in enumerate(bundle.manifest["heads"][h]["supported"]) if s]]
                                  - side[h]).max()) for h in side) if side else 0.0
        rep: Dict[str, Any] = {"experiment": exp.name, "bundle_id": bundle.bundle_id, "bundle_sha256": bundle.bundle_sha256,
                               "encoder": man["encoder"], "evidence_tier_max": man["evidence_tier_max"],
                               "banner": man["training"]["standin_banner"], "role": exp.role,
                               "apply_vs_training_side_max_abs": parity, "n_test_windows": int(len(t.meta)),
                               "n_nonfinite_dropped": int((~out["valid"]).sum()),
                               "test_windows": t.meta.groupby(["dataset"]).agg(windows=("uid", "size"),
                                                                              subjects=("subject", "nunique")).reset_index().to_dict("records"),
                               "heads": {}}
        for h in CLASS_HEADS:
            if h in man["heads"]:
                log(f"{exp.name}: evaluate {h}")
                rep["heads"][h] = eval_class_head(h, bundle, out, t, arr.raw_logits)
        if "transition" in man["heads"]:
            rep["heads"]["transition"] = eval_transition(bundle, out, t, arr.raw_logits)
        if "movement_intensity" in man["heads"]:
            rep["heads"]["movement_intensity"] = eval_intensity(bundle, out, t)
        log(f"{exp.name}: evaluate transition / intensity / OOD")
        rep["ood"] = eval_ood(exp, bundle, out, t, payload["daphnet"], cw, cache_root)
        if exp.save_predictions:
            rep["test_predictions"] = save_predictions(bundle, out, arr, t, os.path.join(bdir, "test_predictions"))
        from .report import _json_safe, render
        json.dumps(_json_safe(rep), allow_nan=False)
        render(dict(rep, integrity={}))           # fail BEFORE the ledger is stamped if the report cannot render
        return rep

    report = vault.evaluate_once(exp.name, bundle.bundle_sha256, evaluator, DECLARED, rerun_reason)
    from .report import write_evaluation
    paths = write_evaluation(report, os.path.join(eval_root, exp.bundle_id))
    for p in paths:
        shutil.copy(p, os.path.join(bdir, os.path.basename(p)))
    report["report_path"] = paths[0]
    return report


def main(argv=None) -> int:
    import argparse
    import warnings
    warnings.filterwarnings("ignore", message=r".*encountered in matmul", category=RuntimeWarning)
    ap = argparse.ArgumentParser(prog="python -m activity_context.inertia.evaluate_heads")
    ap.add_argument("--experiment", required=True)
    ap.add_argument("--rerun-reason")
    a = ap.parse_args(argv)
    rep = evaluate_experiment(get_experiment(a.experiment), rerun_reason=a.rerun_reason)
    print(json.dumps({"report": rep["report_path"], "bundle_sha256": rep["bundle_sha256"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
