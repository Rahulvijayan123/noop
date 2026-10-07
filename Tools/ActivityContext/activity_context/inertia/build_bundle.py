"""Train every head of one experiment and write its bundle through ``bundle.write_bundle`` (P1's authority).

Flow (TRAIN/VAL only — the test split is never loaded here):
assemble -> standardiser on TRAIN -> per head: support, class weights, fit (+ arch rule), calibration on
VAL, operating points on VAL, priors -> transition + movement_intensity -> OOD reference on TRAIN with
the threshold on VAL ID windows (method from the encoder's ood_bench VAL selection) -> manifest (spec §20
fields, ``evidence_tier_max = "shadow"`` for every stand-in) -> write_bundle -> training_report.json.

Provenance (G-7, :mod:`.provenance`): every bundle records ``git_commit`` (HEAD), ``source_tree_sha256`` and
the dirty state of ``Tools/ActivityContext``. :func:`run_experiment` refuses to build when anything there is
uncommitted/untracked unless ``allow_dirty`` (CLI ``--allow-dirty``), which caps the bundle at
``evidence_tier_max = "offline"``. The synthetic smoke path (:func:`train_bundle` called directly) is exempt.
"""

from __future__ import annotations

import json
import os
import shutil
import time
from typing import Any, Dict, Optional

import numpy as np

from . import HEAD_CLASS_ORDERS, INERTIA_AXES, PREPROCESSING_VERSION, UPSTREAM_COMMIT
from . import bundle as B
from . import ood as O
from .metrics import binary_auc as M_auc
from .assemble import activity_keys, any_target, assemble, head_rows
from .cache import CACHE_ROOT
from .contract import InertiaUnavailable
from .experiments import BUNDLES_ROOT, Experiment, get_experiment
from .head_training import train_class_head, train_intensity_head, train_transition_head
from .heads import HEAD_INPUTS, fit_standardizer, numpy_logits
from .integrity import array_sha256, assert_head_inputs
from .mappings import MAPPINGS_PATH, load_mappings
from .splits import combined_sha256, load_splits
from .targets import CLASS_HEADS
from .windows import SPECS

STANDIN_BANNER = "STAND-IN ENCODER — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint"
KNN_KS = (5, 10, 20)


def log(msg: str) -> None:
    import sys
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)
SERVE_HOP_S = 5


def git_info() -> Dict[str, Any]:
    """Provenance of the running code (no environment override; see :mod:`.provenance`)."""
    from .provenance import provenance_info
    return provenance_info()


def _arch_mode(exp: Experiment, head: str, bundles_root: str) -> str:
    if not exp.arch.startswith("from:"):
        return exp.arch
    src = os.path.join(bundles_root, get_experiment(exp.arch[5:]).bundle_id, "manifest.json")
    with open(src) as f:
        return json.load(f)["heads"].get(head, {}).get("arch", "linear")


def _ood_choice(exp: Experiment, bundles_root: str) -> Optional[Dict[str, Any]]:
    if not exp.ood_from:
        return None
    p = os.path.join(bundles_root, get_experiment(exp.ood_from).bundle_id, "manifest.json")
    if not os.path.isfile(p):
        return None
    with open(p) as f:
        return json.load(f)["training"]["ood_selection"]


def fit_ood(exp, cw, tr, va, z_tr, z_va, heads_arrays, heads_meta, choice):
    """OOD reference on TRAIN windows that train some head; thresholds on VAL ID windows."""
    idt, idv = any_target(tr), any_target(va)
    model = O.OODModel(tr.emb[idt], activity_keys(tr.meta[idt]), tr.meta["uid"].to_numpy()[idt])
    sup = heads_meta.get("locomotion", {}).get("supported")

    def raw(z):
        if sup is None:
            return None
        lg = numpy_logits(heads_arrays, "locomotion", heads_meta["locomotion"]["arch"], z)
        return lg[:, np.asarray(sup, bool)]

    scores_v = {"maha_min": model.score("maha_min", va.emb[idv]), "maha_global": model.score("maha_global", va.emb[idv]),
                "maha_rel": model.score("maha_rel", va.emb[idv])}
    for k in KNN_KS:
        scores_v[f"knn@{k}"] = model.score("knn", va.emb[idv], k=k)
    if sup is not None:
        scores_v["energy"] = model.score("energy", None, raw(z_va[idv]))
    thresholds = {m: O.fit_threshold(s) for m, s in scores_v.items()}
    selection = choice
    if exp.role == "ood_bench":
        held = np.zeros(len(va.meta), bool)
        for ds in va.meta["dataset"].unique():
            lab = set(cw.ood_holdout(ds))
            if lab:
                held |= ((va.meta["dataset"] == ds) & va.meta["label"].isin(lab) & va.meta["pure"]).to_numpy()
        ood_v = {"maha_min": model.score("maha_min", va.emb[held]), "maha_global": model.score("maha_global", va.emb[held])}
        for k in KNN_KS:
            ood_v[f"knn@{k}"] = model.score("knn", va.emb[held], k=k)
        if sup is not None:
            ood_v["energy"] = model.score("energy", None, raw(z_va[held]))
        cand = ["maha_global"] + [f"knn@{k}" for k in KNN_KS] + (["energy"] if sup is not None else [])
        bench = ["maha_min"] + cand
        sel = O.select_method({m: scores_v[m] for m in bench}, ood_v, cand)
        sel["val_auroc"] = {m: M_auc(scores_v[m], ood_v[m]) for m in bench}
        sel["excluded_from_bundle"] = {"maha_min": "bundle_math.ood_maha_min is an O(B*C*D^2) scalar einsum over a "
                                       "materialised [B,C,D] array (P1); benchmarked here, not selectable until fixed"}
        selection = {"chosen": sel["chosen"], "val_auroc": sel["val_auroc"], "rule": sel["rule"],
                     "excluded_from_bundle": sel["excluded_from_bundle"],
                     "n_val_id": int(idv.sum()), "n_val_heldout": int(held.sum()), "from": exp.name}
    if selection is None:
        selection = {"chosen": "knn@10", "rule": "default (no ood_bench selection available)", "from": None}
    chosen = selection["chosen"]
    method, k = (("knn", int(chosen.split("@")[1])) if chosen.startswith("knn@") else (chosen, None))
    if method == "energy" and sup is None:
        method, k, chosen = "knn", 10, "knn@10"
    meta = {"method": method, "threshold": float(thresholds[chosen]), "fit": {"split": "val", "quantile": 0.95,
            "reference_split": "train", "n_reference_windows": int(idt.sum()), "n_val_id": int(idv.sum())},
            "thresholds": {m: float(v) for m, v in thresholds.items()}, "n_ref": model.n_ref,
            "classes": model.classes, "shrinkage": model.shrinkage}
    if k is not None:
        meta["k"] = k
    if method == "energy":
        meta["head"] = "locomotion"
    return model.arrays(method), meta, selection


def run_experiment(exp: Experiment, cache_root: Optional[str] = None, bundles_root: Optional[str] = None,
                   force: bool = False, allow_dirty: bool = False) -> Dict[str, Any]:
    from .paths import require_dir
    from .provenance import check_provenance
    if exp.encoder.startswith("inertia-1/"):
        raise InertiaUnavailable("model_missing", "blocked: no checkpoint — no official Inertia-1 checkpoint is "
                                 "publicly available; embed with --checkpoint/$INERTIA1_CKPT_PATH first")
    cache_root = require_dir(cache_root or CACHE_ROOT, "INERTIA_CACHE_DIR / INERTIA_DATA_ROOT (window cache)")
    bundles_root = require_dir(bundles_root or BUNDLES_ROOT, "INERTIA_BUNDLES_DIR / INERTIA_DATA_ROOT (bundles)")
    prov = dict(git_info(), allow_dirty=bool(allow_dirty))
    tier = check_provenance(prov, allow_dirty)              # refuses a dirty source tree unless allow_dirty
    out_dir = os.path.join(bundles_root, exp.bundle_id)
    if os.path.isdir(out_dir) and os.listdir(out_dir):
        if not force:
            return {"bundle_dir": out_dir, "bundle_sha256": B.load_bundle(out_dir).bundle_sha256, "reused": True}
        shutil.rmtree(out_dir)
    t0 = time.time()
    cw = load_mappings()
    specs = [exp.window] + ([exp.trn_window] if exp.trn_window else [])
    data = assemble(exp.encoder, specs, exp.datasets, cw, exp.ood_holdout, exp.train_datasets, ("train", "val"),
                    cache_root)
    sha = train_bundle(exp, data, out_dir, cw, _encoder_info(exp, cache_root), bundles_root, provenance=prov,
                       tier=tier)
    return {"bundle_dir": out_dir, "bundle_sha256": sha, "seconds": round(time.time() - t0, 1),
            "evidence_tier_max": tier}


def training_data_licences(cw, train_datasets) -> Dict[str, Any]:
    """Licences of the data a bundle is trained on (from the crosswalk's ``dataset_roles``), e.g. ``["CC BY 4.0",
    "CC BY-NC-SA 4.0"]``. A bundle listing CC BY-NC-SA 4.0 inherits its non-commercial / share-alike terms."""
    by = {d: cw.doc["dataset_roles"][d]["licence"] for d in train_datasets}
    out: Dict[str, Any] = {"licences": sorted(set(by.values())), "by_dataset": by, "note": None}
    if "CC BY-NC-SA 4.0" in out["licences"]:
        out["note"] = ("trained on CC BY-NC-SA 4.0 data (GOTOV/WEAR; owner decision 2026-10-06): non-commercial use only, "
                       "share-alike; attribution in Tools/ActivityContext/NOTICE.md")
    return out


def recumbent_composition(a, cw) -> Dict[str, Any]:
    """G-2: how much of the recumbent posture target is sleep-period lying (Capture-24 sleep diary labels)."""
    from .mappings import bitmask
    bit = bitmask(["recumbent"], "posture")
    t = a.targets["posture"]
    rec = (t.astype(np.int64) & bit) != 0
    ds, lab = a.meta["dataset"].to_numpy(), a.meta["label"].to_numpy()
    state: Dict[tuple, Optional[str]] = {}
    sleep = np.zeros(len(t), bool)
    for i in np.flatnonzero(rec):
        key = (ds[i], lab[i])
        if key not in state:
            state[key] = cw.transition_state(ds[i], lab[i])
        sleep[i] = state[key] == "sleep"
    n = int(rec.sum())
    return {"recumbent_windows": n, "sleep_period": int(sleep.sum()), "awake_lying": int(n - sleep.sum()),
            "sleep_period_fraction": float(sleep.sum() / n) if n else None,
            "awake_lying_by_dataset": {d: int((rec & ~sleep & (ds == d)).sum()) for d in sorted(set(ds[rec & ~sleep]))},
            "note": "recumbent = mostly sleep-period lying in the training data (Capture-24 sleep diary); awake "
                    "lying is reported separately in every evaluation"}


def train_bundle(exp: Experiment, data, out_dir: str, cw, enc_info: Dict[str, Any], bundles_root: Optional[str] = None,
                 provenance: Optional[Dict[str, Any]] = None, tier: str = "shadow") -> str:
    """Train all heads of ``exp`` on pre-assembled TRAIN/VAL data and write the bundle; returns bundle_sha256.

    ``provenance`` defaults to the running checkout's (recorded, not enforced: enforcement is in
    :func:`run_experiment`); ``tier`` is the bundle's evidence_tier_max ("shadow" | "offline")."""
    bundles_root = bundles_root or BUNDLES_ROOT
    if provenance is None:
        provenance = dict(git_info(), allow_dirty=None)
    if tier not in ("shadow", "offline"):
        raise ValueError(f"a stand-in/offline training run produces shadow or offline bundles, not {tier!r}")
    assert_head_inputs(HEAD_INPUTS)
    if set(data.meta["split"].unique()) - {"train", "val"}:
        raise RuntimeError("train_bundle received windows outside train/val")
    tr, va = data.split("train"), data.split("val")
    used = any_target(tr) | head_rows(tr, "transition")
    mu, sigma = fit_standardizer(tr.emb[used])
    z_tr, z_va = (tr.emb - mu) / sigma, (va.emb - mu) / sigma
    val_sha = array_sha256(va.meta["uid"].to_numpy(), va.meta["subject"].to_numpy())
    arrays: Dict[str, np.ndarray] = {"std.mu": mu, "std.sigma": sigma}
    heads, cal, evidence = {}, {}, {}
    log(f"{exp.name}: train {len(tr.meta)} / val {len(va.meta)} windows, D={mu.shape[0]}")
    for h in CLASS_HEADS:
        log(f"{exp.name}: head {h}")
        r = train_class_head(h, tr, va, z_tr, z_va, cw.set_families(h), _arch_mode(exp, h, bundles_root), exp.seed, val_sha)
        if r is None:
            evidence[h] = {"omitted": "no supported class"}
            continue
        heads[h], a, cal[h], evidence[h] = r
        arrays.update(a)
    if exp.trn_window:
        log(f"{exp.name}: head transition")
        r, evidence["transition"] = train_transition_head(tr, va, z_tr, z_va, exp.seed, val_sha)
        if r is not None:
            heads["transition"], a, cal["transition"] = r
            arrays.update(a)
    r, evidence["movement_intensity"] = train_intensity_head(tr, va, z_tr, z_va, exp.seed)
    if r is not None:
        heads["movement_intensity"], a = r
        arrays.update(a)
        cal["movement_intensity"] = {"method": "none"}
    log(f"{exp.name}: OOD reference")
    ood_arrays, ood_meta, ood_sel = fit_ood(exp, cw, tr, va, z_tr, z_va, arrays, heads, _ood_choice(exp, bundles_root))
    emb_info = next(iter(data.emb_info.values())) if data.emb_info else {"encoder_version": enc_info.get("encoder_version")}
    splits = load_splits(exp.datasets)
    licences = training_data_licences(cw, exp.train_datasets)
    window_s = SPECS[exp.window].window_s
    unit_contract = {"axes": list(INERTIA_AXES), "units": "g", "gravity": "kept", "rate_hz": 20, "normalization": "none"}
    training = {
        "experiment": exp.name, "role": exp.role, "description": exp.description, "seed": exp.seed,
        "standin_banner": STANDIN_BANNER, "head_inputs": list(HEAD_INPUTS),
        "training_datasets": list(exp.train_datasets), "eval_datasets": list(exp.eval_datasets),
        "training_data_licences": licences["licences"], "training_data_licence_by_dataset": licences["by_dataset"],
        "training_data_licence_note": licences["note"],
        "ood_holdout": exp.ood_holdout, "split_manifest_sha256": combined_sha256(splits),
        "split_manifests": {d: s["sha256"] for d, s in splits.items()}, "label_mappings_sha256": cw.sha256,
        "calibration_method": {h: c["method"] for h, c in cal.items()},
        "operating_thresholds": {h: {c: {"status": m["status"][c], "tau": m["tau"][c],
                                         "evidence": evidence[h].get("operating_points", {}).get(c, {}).get("evidence")}
                                     for c in m["status"]} for h, m in heads.items() if "status" in m},
        "ood_selection": ood_sel, "window_policy": {"window_s": window_s, "train_hop_s": {d: SPECS[exp.window].hop_s(d) for d in exp.datasets},
                                                    "eval_hop_s": "same as train (documented in windows.py)",
                                                    "capture24_train_cap": "1000 per (subject, fine label)"},
        "n_windows": {"train": int(len(tr.meta)), "val": int(len(va.meta))}, "embedding_cache": data.emb_info,
        "created_unix": int(time.time()), **provenance,
        "composition": {"posture_recumbent_train": recumbent_composition(tr, cw),
                        "posture_recumbent_val": recumbent_composition(va, cw)},
        "train_class_counts": {h: evidence[h]["support"]["counts"] for h in CLASS_HEADS if "support" in evidence.get(h, {})},
    }
    manifest = {
        "bundle_id": exp.bundle_id, "evidence_tier_max": tier,
        "encoder": {"encoder_id": enc_info["encoder_id"], "embedding_dim": int(mu.shape[0]), "kind": enc_info["kind"],
                    "encoder_version": emb_info["encoder_version"], "checkpoint_sha256": None,
                    "config_sha256": enc_info["config_sha256"], "inertia_repo_commit": UPSTREAM_COMMIT,
                    "extraction_point": enc_info.get("extraction_point")},
        "preprocessing": {"version": PREPROCESSING_VERSION, "window_s": window_s, "hop_s": SERVE_HOP_S, "rate_hz": 20,
                          "axes": list(INERTIA_AXES), "units": "g", "gravity": "kept"},
        "heads": heads, "ood": {}, "training": training,
        # spec §20 names, explicit at top level
        "inertia_repo_commit": UPSTREAM_COMMIT, "inertia_checkpoint_sha256": None, "inertia_config": enc_info.get("config"),
        "embedding_dimension": int(mu.shape[0]), "input_rate": 20, "window_seconds": window_s, "hop_seconds": SERVE_HOP_S,
        "axis_order": list(INERTIA_AXES), "unit_contract": unit_contract,
        "head_architecture": {h: m["arch"] for h, m in heads.items()},
        "head_class_order": {h: list(HEAD_CLASS_ORDERS[h]) for h in heads if h in HEAD_CLASS_ORDERS},
        "training_datasets": list(exp.train_datasets), "training_data_licences": licences["licences"],
        "split_manifest_sha256": training["split_manifest_sha256"],
        "label_mappings_sha256": cw.sha256, "calibration_method": training["calibration_method"],
        "operating_thresholds": training["operating_thresholds"], "git_commit": training["git_commit"],
    }
    with open(MAPPINGS_PATH, "rb") as f:
        mapping_bytes = f.read()
    extra = {"label_mappings.json": mapping_bytes, "split_manifest.json": B.json_bytes(splits),
             "encoder.json": B.json_bytes(enc_info), "training_report.json": B.json_bytes(_jsonable(evidence))}
    return B.write_bundle(out_dir, manifest=_jsonable(manifest), heads_arrays=arrays,
                          calibration=_jsonable({"heads": cal}), ood_arrays=ood_arrays, ood_meta=_jsonable(ood_meta),
                          extra_files=extra)


def _encoder_info(exp: Experiment, cache_root: str) -> Dict[str, Any]:
    from .cache import encoder_slug
    d = os.path.join(cache_root, "emb", encoder_slug(exp.encoder), exp.window)
    js = sorted(f for f in os.listdir(d) if f.endswith(".json"))[0]
    with open(os.path.join(d, js)) as f:
        info = json.load(f)["info"]
    from .registry import build_encoder
    enc = build_encoder(exp.encoder, window_s=SPECS[exp.window].window_s)
    info["config"] = dict(enc.info.config)
    return info


def _jsonable(o):
    if isinstance(o, dict):
        return {str(k): _jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_jsonable(v) for v in o]
    if isinstance(o, np.ndarray):
        return _jsonable(o.tolist())
    if isinstance(o, (np.floating, float)):
        v = float(o)
        return v if np.isfinite(v) else None
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


__all__ = ["run_experiment", "train_bundle", "fit_ood", "git_info", "recumbent_composition", "training_data_licences",
           "STANDIN_BANNER"]
