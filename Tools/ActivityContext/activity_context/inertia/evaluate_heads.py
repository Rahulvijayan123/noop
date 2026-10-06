"""Evaluate ONE frozen bundle ONCE on the held-out test subjects — through ``load_bundle(...).apply(...)`` —
and SEAL the result into the bundle.

    python -m activity_context.inertia.evaluate_heads --experiment primary-hc
    (= python -m activity_context.inertia.pipeline_cli evaluate --experiment primary-hc)

The test windows are assembled only INSIDE :class:`~.integrity.TestVault` (the vault gets a loader, never
arrays); the ledger (``eval/inertia/test_ledger.jsonl``) refuses undeclared experiments and silent
re-evaluations (a rerun needs an enumerated ``--rerun-reason`` and a ``--rerun-detail``). Every number comes
from the production inference path (``HeadBundle.apply`` -> per-window dicts); calibration provenance (fit on
val, val hash != test hash) is asserted inside the vault before the evaluator runs, the head input list
before the vault opens. Per head: pooled, per dataset (datasets with <= 2 test subjects flagged
descriptive) and wrist-only metrics with subject-cluster bootstrap CIs, every class listed, single-label
precision next to set-target scoring, the one-shot test gate per class pooled AND per wrist dataset
(:func:`.abstention.final_status`), and for posture the awake-lying (non-sleep recumbent) subset.
After the ledger stamp, :func:`.bundle.seal_bundle` writes ``test_gate.json`` into the bundle (the served
artifact carries the gate). Results: ``eval/inertia/<bundle_id>/evaluation.{json,md}`` (copied, unlisted, into
the bundle directory).
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
from .bundle import BundleError, gate_document, load_bundle, seal_bundle
from .cache import CACHE_ROOT, CacheError
from .contract import InertiaUnavailable
from .eval_parts import eval_intensity, eval_ood, eval_transition, save_predictions
from .experiments import BUNDLES_ROOT, DECLARED, EVAL_ROOT, Experiment, get_experiment
from .integrity import TestVault, array_sha256, assert_calibration_provenance, assert_head_inputs
from .mappings import load_mappings
from .targets import CLASS_HEADS, Support, bits_to_matrix

N_BOOT = 200
DESCRIPTIVE_MAX_TEST_SUBJECTS = 2       # per-dataset numbers from <= 2 test subjects are descriptive only


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
    def mf1(idx):                                     # headline: union of true and predicted labels (sklearn)
        y, _ = M.attributed_truth(probs[idx], truth[idx])
        return M.macro_f1(M.confusion(y, probs[idx].argmax(1), probs.shape[1]))

    def mf1_present(idx):                             # legacy: classes with test support only
        y, _ = M.attributed_truth(probs[idx], truth[idx])
        cm = M.confusion(y, probs[idx].argmax(1), probs.shape[1])
        return M.macro_f1(cm, [k for k in range(len(sup)) if sup[k] and cm[k].sum() > 0])

    def bacc(idx):
        y, _ = M.attributed_truth(probs[idx], truth[idx])
        return M.balanced_accuracy(M.confusion(y, probs[idx].argmax(1), probs.shape[1]))

    return {"macro_f1": cluster_bootstrap(mf1, subj, strata, N_BOOT),
            "macro_f1_present_supported": cluster_bootstrap(mf1_present, subj, strata, N_BOOT),
            "balanced_accuracy": cluster_bootstrap(bacc, subj, strata, N_BOOT),
            "nll": cluster_bootstrap(lambda i: M.nll(probs[i], truth[i]), subj, strata, N_BOOT)}


def sleep_period_mask(meta, cw) -> np.ndarray:
    """True for windows whose source label is a sleep-period label (crosswalk transition state 'sleep')."""
    ds, lab = meta["dataset"].to_numpy(), meta["label"].to_numpy()
    cache: Dict[tuple, bool] = {}
    out = np.zeros(len(meta), bool)
    for i in range(len(meta)):
        key = (ds[i], lab[i])
        if key not in cache:
            cache[key] = cw.transition_state(ds[i], lab[i]) == "sleep"
        out[i] = cache[key]
    return out


def class_gates(P: np.ndarray, truth: np.ndarray, k: int, tau: float, val_status: str, ds: np.ndarray,
                wrist: np.ndarray) -> Dict[str, Any]:
    """Pooled + per-wrist-dataset one-shot gates at the frozen tau and the resulting final status."""
    pooled = A.check_gate(P, truth, k, tau)
    per = {d: A.check_gate(P[(ds == d) & wrist], truth[(ds == d) & wrist], k, tau, dataset_level=True)
           for d in sorted(np.unique(ds[wrist]))}
    final, reasons = A.final_status(val_status, pooled, per)
    return {"test": pooled, "per_dataset": per, "final_status": final, "reasons": reasons}


def eval_class_head(h: str, bundle, out: Dict, test, raw_logits, cw=None) -> Dict[str, Any]:
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
    rep["single_label"] = M.single_label_prf(P, truth, order, sup.supported)
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
        r["n_test_subjects"] = int(len(np.unique(subj[dm])))
        r["descriptive_only"] = r["n_test_subjects"] <= DESCRIPTIVE_MAX_TEST_SUBJECTS
        rep["per_dataset"][d] = r
    w = is_wrist(meta_t)
    rep["wrist_only"] = {"n": int(w.sum()), "note": "every training/test placement is wrist or forearm; equals pooled"
                         if w.all() else "subset", "macro_f1": M.head_report(P[w], truth[w], order, sup.supported,
                                                                               null_reps=20).get("macro_f1")}
    conf = P.max(axis=1)
    correct = truth[np.arange(len(P)), P.argmax(axis=1)]
    rep["fixed_thresholds"] = A.at_fixed_thresholds(P, truth)
    rep["risk_coverage"] = A.risk_coverage(conf, correct)
    rep["aurc"] = A.aurc(conf, correct)
    single = truth.sum(axis=1) == 1
    gate = {}
    for k, c in enumerate(order):
        if not sup.supported[k]:
            continue
        vs = meta["status"][c]
        tau = float(meta["tau"][c])
        if vs in ("strong", "weak"):
            g = class_gates(P, truth, k, tau, vs, ds, w)
            g["test_single_label"] = A.check_gate(P[single], truth[single], k, tau)
        else:
            g = {"test": None, "per_dataset": {}, "final_status": vs, "reasons": []}
        gate[c] = {"val_status": vs, "tau": meta["tau"][c], **g}
    rep["gate"] = gate
    if h == "posture" and cw is not None and "recumbent" in sup.classes and sup.supported[order.index("recumbent")]:
        rep["awake_lying"] = awake_lying_report(P, truth, order, sup, meta, test.meta[m], cw, ds, w)
    counts = {c: meta["support_counts"][c]["train_windows"] for c in order}
    maj = int(np.argmax([counts[c] if sup.supported[k] else -1 for k, c in enumerate(order)]))
    yhat = np.full(len(P), maj)
    y_att = np.where(truth[:, maj], maj, truth.argmax(axis=1))
    cm = M.confusion(y_att, yhat, K)
    rep["majority_baseline"] = {"class": order[maj], "accuracy": float(truth[:, maj].mean()),
                                "macro_f1": M.macro_f1(cm),
                                "macro_f1_present_supported": M.macro_f1(cm, [k for k in range(K) if sup.supported[k] and cm[k].sum() > 0]),
                                "balanced_accuracy": M.balanced_accuracy(cm)}
    return rep


def awake_lying_report(P, truth, order, sup, meta, meta_t, cw, ds, wrist) -> Dict[str, Any]:
    """G-2: recumbent is mostly sleep-period lying in the training data. Score the recumbent class on the
    NON-sleep windows only (sleep-period labels removed): its precision/recall there and the same one-shot
    gate at the frozen tau. Reported beside the pooled gate; it does not change the served status."""
    k = order.index("recumbent")
    sleep = sleep_period_mask(meta_t, cw)
    awake = ~sleep
    rec_truth = truth[:, k]
    out: Dict[str, Any] = {"label": "recumbent on non-sleep windows (awake lying)",
                           "n_recumbent_truth_windows": int(rec_truth.sum()),
                           "n_sleep_period_recumbent_truth": int((rec_truth & sleep).sum()),
                           "n_awake_lying_truth": int((rec_truth & awake).sum()),
                           "sleep_period_fraction_of_recumbent_truth":
                               float((rec_truth & sleep).sum() / rec_truth.sum()) if rec_truth.any() else None,
                           "by_dataset_awake_lying_truth": {d: int((rec_truth & awake & (ds == d)).sum())
                                                            for d in sorted(np.unique(ds))}}
    if awake.any():
        r = M.head_report(P[awake], truth[awake], order, sup.supported, null_reps=20)
        out["per_class_recumbent"] = r["per_class"]["recumbent"]
        vs = meta["status"]["recumbent"]
        if vs in ("strong", "weak"):
            g = class_gates(P[awake], truth[awake], k, float(meta["tau"]["recumbent"]), vs, ds[awake], wrist[awake])
            out["gate"] = {"val_status": vs, "tau": meta["tau"]["recumbent"], **g,
                           "affects_served_status": False}
    return out


def evaluate_experiment(exp: Experiment, cache_root: Optional[str] = None, bundles_root: Optional[str] = None,
                        eval_root: str = EVAL_ROOT, rerun_reason: Optional[str] = None,
                        rerun_detail: Optional[str] = None) -> Dict[str, Any]:
    from .paths import require_dir
    if exp.encoder.startswith("inertia-1/"):
        raise InertiaUnavailable("model_missing", "blocked: no checkpoint — real Inertia-1 evaluation is blocked")
    cache_root = require_dir(cache_root or CACHE_ROOT, "INERTIA_CACHE_DIR / INERTIA_DATA_ROOT (window cache)")
    bundles_root = require_dir(bundles_root or BUNDLES_ROOT, "INERTIA_BUNDLES_DIR / INERTIA_DATA_ROOT (bundles)")
    bdir = os.path.join(bundles_root, exp.bundle_id)
    bundle = load_bundle(bdir)
    if bundle.sealed:
        raise BundleError("config_mismatch", f"{bdir} is already sealed (evaluated once); retrain to evaluate again")
    man = bundle.manifest
    if man["training"]["experiment"] != exp.name or man["encoder"]["encoder_id"] != exp.encoder:
        raise BundleError("config_mismatch", f"{bdir} was not produced by experiment {exp.name}")
    assert_head_inputs(man["training"]["head_inputs"])
    cw = load_mappings()
    if cw.sha256 != man["label_mappings_sha256"]:
        raise BundleError("config_mismatch", "label_mappings.json changed since the bundle was trained")
    specs = [exp.window] + ([exp.trn_window] if exp.trn_window else [])

    def load_test():                                    # called only inside the vault
        test = assemble(exp.encoder, specs, exp.eval_datasets, cw, False, None, ("test",), cache_root)
        try:
            extra = assemble(exp.encoder, [exp.window], ("daphnet_fog",), cw, False, None, ("ood",), cache_root)
        except CacheError:
            extra = None                                # Daphnet is windowed for w30 only (OOD probe)
        return {"test": test, "daphnet": extra}

    vault = TestVault(load_test, lambda p: [p["test"].meta["uid"].to_numpy(), p["test"].meta["subject"].to_numpy()],
                      os.path.join(eval_root, "test_ledger.jsonl"))

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
                               "provenance": {k: man["training"].get(k) for k in PROVENANCE_KEYS},
                               "training_datasets": list(man["training"].get("training_datasets") or []),
                               "eval_datasets": list(exp.eval_datasets),
                               "training_data_licences": man["training"].get("training_data_licences"),
                               "apply_vs_training_side_max_abs": parity, "n_test_windows": int(len(t.meta)),
                               "n_nonfinite_dropped": int((~out["valid"]).sum()),
                               "test_windows": t.meta.groupby(["dataset"]).agg(windows=("uid", "size"),
                                                                              subjects=("subject", "nunique")).reset_index().to_dict("records"),
                               "heads": {}}
        for h in CLASS_HEADS:
            if h in man["heads"]:
                log(f"{exp.name}: evaluate {h}")
                rep["heads"][h] = eval_class_head(h, bundle, out, t, arr.raw_logits, cw)
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
        gate_document(bundle, dict(rep, integrity={"bundle_sha256": bundle.bundle_sha256, "test_sha256": "0" * 64}))
        return rep

    report = vault.evaluate_once(exp.name, bundle.bundle_sha256, evaluator, DECLARED, rerun_reason, rerun_detail,
                                 before=lambda sha: assert_calibration_provenance(bundle.calibration, sha))
    from .report import _json_safe, write_evaluation
    out_dir = os.path.join(eval_root, exp.bundle_id)
    write_evaluation(report, out_dir)                    # keep the report even if sealing fails
    sealed = seal_bundle(bdir, _json_safe(report))
    report["seal"] = {"sealed_bundle_sha256": sealed.bundle_sha256, "evaluated_bundle_sha256": bundle.bundle_sha256,
                      "test_gate_sha256": sealed.manifest["seal"]["test_gate_sha256"],
                      "final_status": {h: {c: e["final_status"] for c, e in g["classes"].items()}
                                       for h, g in sealed.test_gate["heads"].items()},
                      "merge_into": {h: g.get("merge_into", {}) for h, g in sealed.test_gate["heads"].items()},
                      "decoder_evidence": {h: g.get("decoder_evidence") for h, g in sealed.test_gate["heads"].items()
                                           if "decoder_evidence" in g}}
    paths = write_evaluation(report, out_dir)
    for p in paths:
        shutil.copy(p, os.path.join(bdir, os.path.basename(p)))
    report["report_path"] = paths[0]
    return report


PROVENANCE_KEYS = ("git_commit", "git_dirty", "source_tree_sha256", "source_dirty", "source_dirty_paths",
                   "tools_activity_context_dirty", "dirty_paths", "allow_dirty")


def main(argv=None) -> int:
    import argparse
    import warnings
    warnings.filterwarnings("ignore", message=r".*encountered in matmul", category=RuntimeWarning)
    ap = argparse.ArgumentParser(prog="python -m activity_context.inertia.evaluate_heads")
    from .integrity import RERUN_REASONS
    ap.add_argument("--experiment", required=True)
    ap.add_argument("--rerun-reason", choices=sorted(RERUN_REASONS))
    ap.add_argument("--rerun-detail", help="free text: what happened and why (required with --rerun-reason)")
    a = ap.parse_args(argv)
    rep = evaluate_experiment(get_experiment(a.experiment), rerun_reason=a.rerun_reason, rerun_detail=a.rerun_detail)
    print(json.dumps({"report": rep["report_path"], "bundle_sha256": rep["bundle_sha256"],
                      "sealed_bundle_sha256": rep["seal"]["sealed_bundle_sha256"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
