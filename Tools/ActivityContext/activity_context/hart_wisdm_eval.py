"""HART on WISDM held-out subjects: two protocols, calibration, and replay outputs (offline research CLI).

Protocol (i), "RESULTS.md": the training-path windows of activity-train (eval_data.npz / val_data.npz,
now built by wisdm-watch-loader-2) through ``HARTModel.predict_window`` and ``evaluate.evaluate``.

Protocol (ii), "production-faithful" (agent R, activity_context.inertia.replay_data): every WISDM
(subject, activity block) resampled per block from its native rate to 30 Hz by
``replay_data.wisdm_blocks_for_subject``, windowed exactly as serve.classify_windows windows a request
(``replay_data.serve_windows``), windows without gyro skipped and counted, ``HARTModel.predict_window``
per window. The per-window outputs are written in R's format (``flatten_hart`` keys, probabilities
rounded to 6 dp like serve) so a system comparison can swap one HART artifact for another.

Both protocols report coverage, accepted precision, macro-F1 over the four supported classes,
per-class P/R/F1, the confusion matrix and transition delays, plus calibration diagnostics of the RAW
softmax aggregated to the ontology (NLL, Brier, ECE) and what a temperature fitted on the VAL subjects
would change (report only: serve and the Swift adapter are untouched).

Needs the [model] extra (torch / transformers / granite-tsfm). Inference is single-threaded per
process (HARTModel sets torch threads to 1); ``--jobs`` processes run in parallel.

Test ledger (audit G2 E-2): every opening of the HART WISDM test subjects goes through
``inertia.integrity.TestVault`` with its own ledger ``eval/hart/test_ledger.jsonl`` (experiment
:data:`HART_EXPERIMENT`, pre-registered in :data:`HART_DECLARED`). The test windows are loaded only inside
``evaluate_once``; a second evaluation needs an enumerated ``--rerun-reason`` plus ``--rerun-detail``. The
evaluations made before the ledger existed are recorded by ``--record-historical`` as entries labelled
``historical: true`` / "recorded after the fact from RESULTS.md; first evaluation was not ledgered" (never as
if they had been ledgered at the time). Each entry carries ``per_dataset_split_sha256`` =
``{"wisdm2019_watch": <splits/wisdm2019_watch.json sha256>}``: the HART test subjects ARE the Inertia heads'
WISDM test subjects (same seed-42 split), so reuse can be counted across the two ledgers.

``--repair-sensitivity`` (audit G2 E-1): the loader (``wisdm.py``) linearly interpolates single missing
samples (option ``wisdm-single-dropout-linear-1``); the eval npz records ``n_repaired`` per window. The run
reports both protocols for every model with all windows and excluding windows that contain a repaired
sample (protocol ii: windows whose span contains a repaired raw instant), plus subject-cluster bootstrap CIs
of macro-F1 and of the paired v1 - v0 difference (audit G2 E-3).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .evaluate import (SUPPORTED, accepted_precision, aggregate_softmax, calibration_metrics,
                       evaluate, fit_temperature, smooth_predictions, transition_delay_censored,
                       _transition_delay)
from .model import abstain

TEST_SUBJECTS = (1605, 1607, 1617, 1627, 1638, 1646, 1648, 1650)
VAL_SUBJECTS = (1618, 1620, 1623, 1624, 1629, 1634, 1637, 1639)

EVAL_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "eval")
HART_LEDGER = os.path.join(EVAL_DIR, "hart", "test_ledger.jsonl")
HART_EXPERIMENT = "hart-wisdm/test"
HART_DECLARED = (HART_EXPERIMENT,)
WISDM_SPLIT_DATASET = "wisdm2019_watch"
N_BOOT = 1000
HISTORICAL_NOTE = "recorded after the fact from RESULTS.md; first evaluation was not ledgered"


# ---------------------------------------------------------------------------
# Worker functions (one HARTModel per process)
# ---------------------------------------------------------------------------

_MODEL_CACHE: Dict[Tuple[str, str], Any] = {}


def _model(manifest_path: str, checkpoint: str):
    from .manifest import load_manifest
    from .model import HARTModel
    key = (manifest_path, checkpoint)
    if key not in _MODEL_CACHE:
        _MODEL_CACHE[key] = HARTModel(load_manifest(manifest_path), checkpoint)
    return _MODEL_CACHE[key]


def _predict_chunk(args: Tuple[str, str, str, int, int]) -> Dict[str, np.ndarray]:
    """Protocol (i): logits / ontology probs / label for windows [lo, hi) of an npz."""
    manifest_path, checkpoint, npz_path, lo, hi = args
    model = _model(manifest_path, checkpoint)
    x = np.load(npz_path, allow_pickle=True)["X"][lo:hi]
    logits, probs, labels = [], [], []
    for w in x:
        p = model.predict_window(np.asarray(w, dtype=np.float64))
        logits.append(p.logits)
        probs.append([p.probs.get(c, 0.0) for c in SUPPORTED])
        labels.append(p.label)
    return {"logits": np.asarray(logits), "probs": np.asarray(probs), "label": np.asarray(labels)}


def _replay_subject(args: Tuple[str, str, int, str]) -> Dict[str, Any]:
    """Protocol (ii): R's per-block stream + serve windows for one subject, with logits kept."""
    from .features import window_features
    from .inertia import replay_data as RD
    manifest_path, checkpoint, subject, wisdm_dir = args
    model = _model(manifest_path, checkpoint)
    blocks, wins = [], []
    for b in RD.wisdm_blocks_for_subject(subject, wisdm_dir):
        ws = RD.serve_windows(b.data30, start_ts=0)
        n_missing = 0
        for w in ws:
            if not np.isfinite(w.data).all():
                n_missing += 1
                continue
            pred = model.predict_window(w.data)
            rec = RD.hart_window_record(w, pred, window_features(w))
            rec["logits"] = [float(v) for v in pred.logits]
            rec["block_id"] = b.block_id
            rec["activity"] = b.activity
            rec["acc_nominal_hz"] = b.acc_nominal_hz
            wins.append(rec)
        blocks.append({"block_id": b.block_id, "subject": b.subject, "activity": b.activity,
                       "index": b.index, "t0_ns": b.t0_ns, "duration_s": round(b.duration_s, 3),
                       "acc_measured_hz": round(b.acc_measured_hz, 3), "acc_nominal_hz": b.acc_nominal_hz,
                       "n_acc": b.n_acc,
                       "gyr_measured_hz": None if b.gyr_measured_hz is None else round(b.gyr_measured_hz, 3),
                       "gyr_nominal_hz": b.gyr_nominal_hz, "n_gyr": b.n_gyr,
                       "gyro_coverage": round(b.gyro_coverage, 4),
                       "n_seconds": int(b.data30.shape[0] // 30), "n_windows_grid": len(ws),
                       "n_windows_gyro_missing": n_missing})
    return {"subject": subject, "blocks": blocks, "windows": wins}


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def _groups(manifest) -> np.ndarray:
    return np.asarray([SUPPORTED.index(manifest.label_mapping.get(c, "other_movement"))
                       for c in manifest.class_map], dtype=np.int64)


def _abstain_rows(p: np.ndarray, thresholds: Dict[str, float]) -> List[str]:
    return [abstain({c: float(v) for c, v in zip(SUPPORTED, row)}, float(thresholds["max_prob"]),
                    float(thresholds["margin"])) for row in p]


def coarse_report(y: Sequence[str], pred: Sequence[str], probs: np.ndarray,
                  sessions: Optional[Sequence] = None) -> Dict[str, Any]:
    """Coverage, accepted precision, macro-F1, per-class P/R/F1, confusion, delays, calibration."""
    y = np.asarray([str(v) for v in y])
    pred = np.asarray([str(v) for v in pred])
    labels = list(SUPPORTED) + ["unknown"]
    conf = {t: {p: int(np.sum((y == t) & (pred == p))) for p in labels} for t in SUPPORTED}
    per, f1s = {}, []
    for c in SUPPORTED:
        tp = int(np.sum((y == c) & (pred == c)))
        fp = int(np.sum((y != c) & (pred == c)))
        fn = int(np.sum((y == c) & (pred != c)))
        pr = tp / (tp + fp) if tp + fp else 0.0
        rc = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * pr * rc / (pr + rc) if pr + rc else 0.0
        f1s.append(f1)
        per[c] = {"count": int(np.sum(y == c)), "tp": tp, "fp": fp, "fn": fn,
                  "precision": round(pr, 4), "recall": round(rc, 4), "f1": round(f1, 4)}
    acc = pred != "unknown"
    sess = None
    if sessions is not None:
        codes = {k: i for i, k in enumerate(dict.fromkeys(str(s) for s in sessions))}
        sess = np.asarray([codes[str(s)] for s in sessions])
    smoothed = smooth_predictions(list(pred), sessions=sess)
    y_idx = np.asarray([SUPPORTED.index(t) for t in y], dtype=np.int64)
    return {
        "n_windows": int(len(y)), "n_accepted": int(acc.sum()),
        "coverage": round(float(acc.mean()), 4) if len(y) else 0.0,
        "accepted_precision": accepted_precision(conf),
        "macro_f1_supported": round(float(np.mean(f1s)), 4),
        "per_class": per, "confusion": conf,
        "prediction_counts": {l: int(np.sum(pred == l)) for l in labels},
        "transition_delay_s": _transition_delay(y, list(pred)),
        "transition_delay_policy_s": _transition_delay(y, list(pred), smoothed),
        "transition_delay_censored_s": transition_delay_censored(y, list(pred)),
        "transition_delay_censored_policy_s": transition_delay_censored(y, smoothed),
        "calibration": calibration_metrics(probs, y_idx),
    }


def temperature_report(val_logits: np.ndarray, val_y: Sequence[str], test_logits: np.ndarray,
                       test_y: Sequence[str], groups: np.ndarray, thresholds: Dict[str, float],
                       sessions: Optional[Sequence] = None) -> Dict[str, Any]:
    """Fit T on VAL (ontology NLL of the aggregated softmax); report test before/after T."""
    vy = np.asarray([SUPPORTED.index(str(t)) for t in val_y])
    t = fit_temperature(val_logits, vy, groups, len(SUPPORTED))
    p_val_raw = aggregate_softmax(val_logits, groups, len(SUPPORTED))
    p_val_t = aggregate_softmax(val_logits, groups, len(SUPPORTED), t)
    p_test_t = aggregate_softmax(test_logits, groups, len(SUPPORTED), t)
    pred_t = _abstain_rows(p_test_t, thresholds)
    rep = coarse_report(test_y, pred_t, p_test_t, sessions)
    return {"temperature": round(t, 4), "fit_on": "VAL subjects (ontology NLL)",
            "val_calibration_raw": calibration_metrics(p_val_raw, vy),
            "val_calibration_T": calibration_metrics(p_val_t, vy),
            "test_with_T": {k: rep[k] for k in ("n_windows", "n_accepted", "coverage", "accepted_precision",
                                               "macro_f1_supported", "per_class", "calibration",
                                               "prediction_counts")}}


def _strip_reliability(d: Any) -> Any:
    """Drop the per-bin reliability lists (keeps summary JSON small); they stay in the full report."""
    if isinstance(d, dict):
        return {k: _strip_reliability(v) for k, v in d.items() if k != "reliability"}
    return d


# ---------------------------------------------------------------------------
# Protocol drivers
# ---------------------------------------------------------------------------

def protocol_i(name: str, manifest_path: str, checkpoint: str, eval_npz: str, val_npz: str,
               jobs: int) -> Dict[str, Any]:
    from .manifest import load_manifest
    man = load_manifest(manifest_path)
    out: Dict[str, Any] = {}
    preds: Dict[str, Dict[str, np.ndarray]] = {}
    for split, path in (("test", eval_npz), ("val", val_npz)):
        n = int(np.load(path, allow_pickle=True)["X"].shape[0])
        step = max(1, -(-n // (jobs * 4)))
        work = [(manifest_path, checkpoint, path, lo, min(n, lo + step)) for lo in range(0, n, step)]
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            parts = list(ex.map(_predict_chunk, work))
        preds[split] = {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}
    z = np.load(eval_npz, allow_pickle=True)
    it = iter(zip(preds["test"]["label"], preds["test"]["probs"]))

    def cached(_w):
        lab, pr = next(it)
        return str(lab), {c: float(v) for c, v in zip(SUPPORTED, pr)}

    rep = evaluate(z["X"], z["y_ontology"], cached, man.thresholds, letters=z["letters"],
                   subjects=z["subjects"], sessions=z["sessions"])
    zv = np.load(val_npz, allow_pickle=True)
    val_y = zv["y_ontology"] if "y_ontology" in zv.files else np.asarray(
        [man.label_mapping.get(str(zv["letters"][i]), "other_movement") for i in zv["y"]])
    rep["temperature_scaling"] = temperature_report(
        preds["val"]["logits"], val_y, preds["test"]["logits"], z["y_ontology"], _groups(man),
        man.thresholds, sessions=z["sessions"])
    rep["model_version"] = man.model_version
    out["report"] = rep
    out["val_raw"] = {"n_windows": int(len(val_y)), "calibration": calibration_metrics(
        preds["val"]["probs"], np.asarray([SUPPORTED.index(str(t)) for t in val_y]))}
    return out


def protocol_ii(name: str, manifest_path: str, checkpoint: str, wisdm_dir: str, jobs: int,
                ) -> Dict[str, Any]:
    from .manifest import load_manifest
    man = load_manifest(manifest_path)
    subs = list(TEST_SUBJECTS) + list(VAL_SUBJECTS)
    with ProcessPoolExecutor(max_workers=jobs) as ex:
        docs = list(ex.map(_replay_subject, [(manifest_path, checkpoint, s, wisdm_dir) for s in subs]))
    by_sub = {d["subject"]: d for d in docs}
    res: Dict[str, Any] = {"model_version": man.model_version,
                           "checkpoint_sha256": man.checkpoint["files"]["model.safetensors"]["sha256"],
                           "splits": {}}
    flat_logits = {}
    for split, ss in (("test", TEST_SUBJECTS), ("val", VAL_SUBJECTS)):
        wins = [w for s in ss for w in by_sub[s]["windows"]]
        y = [man.label_mapping.get(w["activity"], "other_movement") for w in wins]
        probs = np.asarray([[w["probs"].get(c, 0.0) for c in SUPPORTED] for w in wins])
        pred = [w["label"] for w in wins]
        logits = np.asarray([w["logits"] for w in wins])
        flat_logits[split] = (logits, y, [w["block_id"] for w in wins])
        rep = coarse_report(y, pred, probs, sessions=[w["block_id"] for w in wins])
        subj = np.asarray([int(w["block_id"].split("-")[1]) for w in wins])
        rep["per_subject"] = {}
        for s in ss:
            m = subj == s
            acc_m = m & (np.asarray(pred) != "unknown")
            ok = acc_m & (np.asarray(pred) == np.asarray(y))
            rep["per_subject"][str(s)] = {"windows": int(m.sum()), "accepted": int(acc_m.sum()),
                                          "coverage": round(float(acc_m.sum() / max(1, m.sum())), 4),
                                          "accepted_accuracy": round(float(ok.sum() / max(1, acc_m.sum())), 4)}
        hz = np.asarray([w["acc_nominal_hz"] for w in wins])
        rep["by_native_rate"] = {}
        for r in sorted(set(hz.tolist())):
            m = hz == r
            sub = coarse_report(np.asarray(y)[m], np.asarray(pred)[m], probs[m])
            rep["by_native_rate"][f"{r}hz"] = {k: sub[k] for k in ("n_windows", "coverage", "accepted_precision",
                                                                    "macro_f1_supported")}
        letters = np.asarray([w["activity"] for w in wins])
        rep["per_letter"] = {L: {"truth": man.label_mapping.get(L, "other_movement"),
                                 "windows": int((letters == L).sum()),
                                 "pred": dict(Counter(np.asarray(pred)[letters == L].tolist()))}
                             for L in sorted(set(letters.tolist()))}
        rep["n_windows_gyro_missing"] = int(sum(b["n_windows_gyro_missing"] for s in ss
                                                for b in by_sub[s]["blocks"]))
        res["splits"][split] = rep
    lt, yt, st = flat_logits["test"]
    lv, yv, _ = flat_logits["val"]
    res["splits"]["test"]["temperature_scaling"] = temperature_report(
        lv, yv, lt, yt, _groups(man), man.thresholds, sessions=st)
    res["_docs"] = by_sub
    return res


def write_replay_outputs(docs: Dict[int, Dict[str, Any]], manifest_path: str, out_dir: str,
                         prefix: str) -> Dict[str, str]:
    """R's per-window format (research/inertia-replay/hart_wisdm_{split}.{npz,json})."""
    from .inertia.replay_data import COARSE_ORDER, FEAT_KEYS, hart_accuracy
    from .manifest import load_manifest
    man = load_manifest(manifest_path)
    paths = {}
    for split, ss in (("test", TEST_SUBJECTS), ("val", VAL_SUBJECTS)):
        wins = [w for s in ss for w in docs[s]["windows"]]
        flat = {
            "subject": np.asarray([int(w["block_id"].split("-")[1]) for w in wins], dtype=np.int64),
            "block_id": np.asarray([w["block_id"] for w in wins]),
            "activity": np.asarray([w["activity"] for w in wins]),
            "acc_nominal_hz": np.asarray([w["acc_nominal_hz"] for w in wins], dtype=np.int64),
            "s": np.asarray([w["s"] for w in wins], dtype=np.float64),
            "e": np.asarray([w["e"] for w in wins], dtype=np.float64),
            "label": np.asarray([w["label"] for w in wins]),
            "probs": np.asarray([[w["probs"].get(c, 0.0) for c in COARSE_ORDER] for w in wins],
                                dtype=np.float64).reshape(-1, len(COARSE_ORDER)),
            "probs_order": np.asarray(COARSE_ORDER),
            "feat": np.asarray([[np.nan if w["feat"].get(k) is None else float(w["feat"][k])
                                 for k in FEAT_KEYS] for w in wins],
                               dtype=np.float64).reshape(-1, len(FEAT_KEYS)),
            "feat_keys": np.asarray(FEAT_KEYS),
        }
        npz = os.path.join(out_dir, f"{prefix}_{split}.npz")
        np.savez_compressed(npz, **flat)
        blocks = [b for s in ss for b in docs[s]["blocks"]]
        doc = {"split": split, "subjects": list(ss), "gyro_mode": "real", "n_windows": int(len(wins)),
               "model_version": man.model_version,
               "checkpoint_sha256": man.checkpoint["files"]["model.safetensors"]["sha256"],
               "time_base": "seconds from the block's first accel sample (each (subject, activity block) is "
                            "its own recording)",
               "window_semantics": "serve.py: 4 s / 2 s grid anchored at block start, 1 s FIR-transient "
                                   "margin at both edges, fully inside",
               "probs_rounding": "6 dp like serve.classify_windows",
               "label": "manifest abstention max_prob>=0.80 & margin>=0.15",
               "producer": "activity_context.hart_wisdm_eval (replay_data.wisdm_blocks_for_subject + "
                           "serve_windows + HARTModel.predict_window; same stream/window code as R's "
                           "hart_wisdm_{split})",
               "blocks": blocks,
               "accuracy_vs_manifest_label_mapping": hart_accuracy(flat, man.label_mapping)}
        js = os.path.join(out_dir, f"{prefix}_{split}.json")
        with open(js, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1)
        paths[split] = npz
    return paths


def compare_with_reference(docs: Dict[int, Dict[str, Any]], ref_npz: str,
                           subjects: Sequence[int] = TEST_SUBJECTS) -> Dict[str, Any]:
    """Check this driver reproduces an existing R output (same model): windows, labels, probs."""
    z = np.load(ref_npz, allow_pickle=False)
    wins = [w for s in subjects for w in docs[s]["windows"]]
    ids = np.asarray([w["block_id"] for w in wins])
    s = np.asarray([w["s"] for w in wins])
    lab = np.asarray([w["label"] for w in wins])
    pr = np.asarray([[w["probs"].get(c, 0.0) for c in SUPPORTED] for w in wins])
    same_windows = len(ids) == len(z["block_id"]) and bool(np.all(ids == z["block_id"])) \
        and bool(np.all(s == z["s"]))
    out = {"reference": ref_npz, "n": int(len(ids)), "n_reference": int(len(z["block_id"])),
           "same_windows": same_windows}
    if same_windows:
        out["label_agreement"] = round(float(np.mean(lab == z["label"])), 6)
        out["max_abs_prob_diff"] = float(np.max(np.abs(pr - z["probs"])))
    return out


# ---------------------------------------------------------------------------
# Test ledger (G2 E-2)
# ---------------------------------------------------------------------------

def test_identity_arrays(npz_path: str) -> List[np.ndarray]:
    """The arrays whose hash identifies a HART test-window set: subject, session (piece) and letter of every
    window (never the samples)."""
    z = np.load(npz_path, allow_pickle=True)
    return [np.asarray(z["subjects"]), np.asarray(z["sessions"]), np.asarray(z["letters"]).astype(str)]


def dataset_splits() -> Dict[str, str]:
    """{wisdm2019_watch: sha256 of the frozen split manifest} — its test subjects are the HART test subjects."""
    from .inertia.splits import load_split
    doc = load_split(WISDM_SPLIT_DATASET)
    if sorted(int(x) for x in doc["test_subjects"]) != sorted(TEST_SUBJECTS):
        raise ValueError("splits/wisdm2019_watch.json test subjects differ from the HART test subjects")
    return {WISDM_SPLIT_DATASET: doc["sha256"]}


def models_identity(models: Dict[str, Tuple[str, str]]) -> str:
    """'name:<model.safetensors sha256>' joined by '+' (the HART analogue of a bundle hash)."""
    from .manifest import load_manifest
    return "+".join(f"{n}:{load_manifest(mp).checkpoint['files']['model.safetensors']['sha256']}"
                    for n, (mp, _) in sorted(models.items()))


def historical_entries(v0_eval_npz: str, v1_eval_npz: str, v0_sha: str, v1_sha: str) -> List[Dict[str, Any]]:
    """The two evaluations of the HART test subjects made before this ledger existed (RESULTS.md)."""
    from .inertia.integrity import array_sha256
    splits = dataset_splits()
    common = {"experiment": HART_EXPERIMENT, "historical": True, "recorded_after_the_fact": HISTORICAL_NOTE,
              "rerun_reason": None, "rerun_detail": None, "rerun_reason_text": None,
              "per_dataset_split_sha256": splits, "time_recorded": int(__import__("time").time())}
    return [
        dict(common, bundle_sha256=f"v0:{v0_sha}", test_sha256=array_sha256(*test_identity_arrays(v0_eval_npz)),
             time=None, evaluated_on="on or before 2026-10-02 16:49 PDT (RESULTS.md commit 4832b1ac); exact time not "
                                     "recorded",
             n_test_evaluations=1, n_evaluations_of_experiment_any_split=1,
             n_evaluations_on_this_test_split=1, n_evaluations_per_dataset_split={WISDM_SPLIT_DATASET: 1},
             source="eval/RESULTS.md, top section (hart-wisdm-v0 on its own v0-loader test windows, 15,363 "
                    "windows; activity_context.evaluate)"),
        dict(common, bundle_sha256=f"v0:{v0_sha}+v1:{v1_sha}",
             test_sha256=array_sha256(*test_identity_arrays(v1_eval_npz)), time=None,
             evaluated_on="2026-10-06 01:10 PDT (eval_v0_v1.json written; RESULTS.md commit 5a8a0743)",
             n_test_evaluations=1,
             n_evaluations_of_experiment_any_split=2, n_evaluations_on_this_test_split=1,
             n_evaluations_per_dataset_split={WISDM_SPLIT_DATASET: 2},
             source="eval/RESULTS.md, section hart-wisdm-v1 (v0 and v1, protocols i and ii; "
                    "research/hart-v1/eval_v0_v1.json, 2026-10-06)"),
    ]


def record_historical(ledger: str, entries: Sequence[Dict[str, Any]]) -> int:
    """Append the historical entries once (refuses when the ledger already has any entry)."""
    if os.path.exists(ledger) and any(line.strip() for line in open(ledger)):
        raise SystemExit(f"{ledger} already has entries; historical entries are recorded once, first")
    os.makedirs(os.path.dirname(ledger), exist_ok=True)
    with open(ledger, "a", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e, sort_keys=True) + "\n")
    return len(entries)


def _vault(eval_npz: str, ledger: str, extra_loader=None):
    from .inertia.integrity import TestVault

    def load():                                            # called only inside evaluate_once
        payload = {"eval_npz": eval_npz, "identity": test_identity_arrays(eval_npz)}
        if extra_loader is not None:
            payload.update(extra_loader())
        return payload
    return TestVault(load, lambda p: p["identity"], ledger)


def _ledger_history(entry: Dict[str, Any]) -> Dict[str, str]:
    return dict(entry.get("per_dataset_split_sha256") or {})


# ---------------------------------------------------------------------------
# Repair sensitivity + bootstrap (G2 E-1, E-3)
# ---------------------------------------------------------------------------

def macro_f1_labels(y: np.ndarray, pred: np.ndarray) -> float:
    """Macro-F1 over the 4 supported classes; an abstention ('unknown') counts as a miss (recall)."""
    f1s = []
    for c in SUPPORTED:
        tp = float(np.sum((y == c) & (pred == c)))
        fp = float(np.sum((y != c) & (pred == c)))
        fn = float(np.sum((y == c) & (pred != c)))
        p = tp / (tp + fp) if tp + fp else 0.0
        r = tp / (tp + fn) if tp + fn else 0.0
        f1s.append(2 * p * r / (p + r) if p + r else 0.0)
    return float(np.mean(f1s))


def bootstrap_block(y: np.ndarray, preds: Dict[str, np.ndarray], subjects: np.ndarray, n_boot: int = N_BOOT,
                    pair: Tuple[str, str] = ("v0", "v1")) -> Dict[str, Any]:
    """Subject-cluster bootstrap (8 test subjects; percentile CI under-covers) of macro-F1, coverage and
    accepted precision per model, and of the paired difference pair[1] - pair[0] on the same resamples."""
    from .inertia.bootstrap import cluster_bootstrap
    y = np.asarray(y).astype(str)
    out: Dict[str, Any] = {"n_boot": n_boot, "seed": 0, "unit": "test subject", "n_windows": int(len(y))}

    def cov(p):
        return lambda i: float(np.mean(p[i] != "unknown")) if len(i) else float("nan")

    def acc_prec(p):
        def m(i):
            a = p[i] != "unknown"
            return float(np.mean(p[i][a] == y[i][a])) if a.any() else float("nan")
        return m
    for name, p in preds.items():
        p = np.asarray(p).astype(str)
        out[name] = {"macro_f1": cluster_bootstrap(lambda i, p=p: macro_f1_labels(y[i], p[i]), subjects, None, n_boot),
                     "coverage": cluster_bootstrap(cov(p), subjects, None, n_boot),
                     "accepted_precision": cluster_bootstrap(acc_prec(p), subjects, None, n_boot)}
    a, b = pair
    if a in preds and b in preds:
        pa, pb = np.asarray(preds[a]).astype(str), np.asarray(preds[b]).astype(str)
        out[f"{b}_minus_{a}"] = {
            "macro_f1": cluster_bootstrap(lambda i: macro_f1_labels(y[i], pb[i]) - macro_f1_labels(y[i], pa[i]),
                                          subjects, None, n_boot),
            "coverage": cluster_bootstrap(lambda i: float(np.mean(pb[i] != "unknown") - np.mean(pa[i] != "unknown")),
                                          subjects, None, n_boot)}
    return out


def _brief(rep: Dict[str, Any]) -> Dict[str, Any]:
    return {k: rep[k] for k in ("n_windows", "n_accepted", "coverage", "accepted_precision", "macro_f1_supported",
                                "per_class", "confusion", "prediction_counts")}


def repaired_instants(wisdm_dir: str, subjects: Sequence[int], repair: str) -> Dict[int, np.ndarray]:
    """Raw timestamps (ns) of every repaired sample (accel + gyro) per subject (wisdm.load_subject)."""
    from . import wisdm as W
    return {int(s): W.load_subject(wisdm_dir, int(s), repair=repair).repaired_ts_ns for s in subjects}


def protocol_ii_repaired(npz: str, js: str, instants: Dict[int, np.ndarray]) -> np.ndarray:
    """Per protocol-(ii) window: repaired raw instants inside [t0 + s, t0 + e] (block t0 = first accel ns)."""
    z = np.load(npz, allow_pickle=False)
    with open(js, encoding="utf-8") as f:
        t0 = {b["block_id"]: int(b["t0_ns"]) for b in json.load(f)["blocks"]}
    out = np.zeros(len(z["block_id"]), dtype=np.int64)
    for i, (bid, s, e, subj) in enumerate(zip(z["block_id"], z["s"], z["e"], z["subject"])):
        rt = instants.get(int(subj))
        if rt is None or not rt.size:
            continue
        lo, hi = t0[str(bid)] + int(round(float(s) * 1e9)), t0[str(bid)] + int(round(float(e) * 1e9))
        out[i] = int(np.searchsorted(rt, hi, side="right") - np.searchsorted(rt, lo, side="left"))
    return out


def repair_sensitivity(models: Dict[str, Tuple[str, str]], payload: Dict[str, Any], jobs: int) -> Dict[str, Any]:
    """The evaluator of ``--repair-sensitivity`` (runs inside the vault)."""
    from .manifest import load_manifest
    z = np.load(payload["eval_npz"], allow_pickle=True)
    if "n_repaired" not in z.files:
        raise SystemExit("the eval npz has no n_repaired (rebuild it with activity_context.train from this commit)")
    y = np.asarray(z["y_ontology"]).astype(str)
    subj = np.asarray(z["subjects"])
    n_rep, n_rep05 = np.asarray(z["n_repaired"]), np.asarray(z["n_repaired_pm05s"])
    n = int(z["X"].shape[0])
    rep: Dict[str, Any] = {"protocol_i": {"n_windows": n, "n_windows_with_repaired": int((n_rep > 0).sum()),
                                          "n_windows_with_repaired_pm0.5s": int((n_rep05 > 0).sum()),
                                          "repaired_windows_by_subject": {str(s): int(((subj == s) & (n_rep > 0)).sum())
                                                                          for s in sorted(set(subj.tolist()))
                                                                          if ((subj == s) & (n_rep > 0)).any()},
                                          "models": {}},
                           "protocol_ii": {"models": {}}}
    preds_i: Dict[str, np.ndarray] = {}
    for name, (mp, cp) in models.items():
        step = max(1, -(-n // (jobs * 4)))
        work = [(mp, cp, payload["eval_npz"], lo, min(n, lo + step)) for lo in range(0, n, step)]
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            parts = list(ex.map(_predict_chunk, work))
        lab = np.concatenate([p["label"] for p in parts]).astype(str)
        probs = np.concatenate([p["probs"] for p in parts])
        preds_i[name] = lab
        keep, keep05 = n_rep == 0, n_rep05 == 0
        rep["protocol_i"]["models"][name] = {
            "all_windows": _brief(coarse_report(y, lab, probs, sessions=z["sessions"])),
            "excluding_repaired": _brief(coarse_report(y[keep], lab[keep], probs[keep], sessions=z["sessions"][keep])),
            "excluding_repaired_pm0.5s": _brief(coarse_report(y[keep05], lab[keep05], probs[keep05],
                                                              sessions=z["sessions"][keep05])),
            "subject_1638": {"all": _brief(coarse_report(y[subj == 1638], lab[subj == 1638], probs[subj == 1638])),
                             "excluding_repaired": _brief(coarse_report(y[(subj == 1638) & keep],
                                                                        lab[(subj == 1638) & keep],
                                                                        probs[(subj == 1638) & keep]))}}
    rep["protocol_i"]["bootstrap_all_windows"] = bootstrap_block(y, preds_i, subj)
    rep["protocol_i"]["bootstrap_excluding_repaired"] = bootstrap_block(y[n_rep == 0], {k: v[n_rep == 0] for k, v in
                                                                                          preds_i.items()}, subj[n_rep == 0])
    preds_ii: Dict[str, np.ndarray] = {}
    y_ii = subj_ii = None
    for name, (npz, js) in (payload.get("replay") or {}).items():
        man = load_manifest(models[name][0])
        zz = np.load(npz, allow_pickle=False)
        yy = np.asarray([man.label_mapping.get(str(a), "other_movement") for a in zz["activity"]])
        lab = np.asarray(zz["label"]).astype(str)
        probs = np.asarray(zz["probs"])
        k_rep = protocol_ii_repaired(npz, js, payload["instants"])
        keep = k_rep == 0
        rep["protocol_ii"]["models"][name] = {
            "source": os.path.basename(npz), "n_windows": int(len(lab)), "n_windows_with_repaired": int((~keep).sum()),
            "all_windows": _brief(coarse_report(yy, lab, probs, sessions=zz["block_id"])),
            "excluding_repaired": _brief(coarse_report(yy[keep], lab[keep], probs[keep], sessions=zz["block_id"][keep]))}
        if y_ii is None:
            y_ii, subj_ii, ids = yy, np.asarray(zz["subject"]), (zz["block_id"], zz["s"])
        elif not (np.array_equal(ids[0], zz["block_id"]) and np.array_equal(ids[1], zz["s"])):
            raise SystemExit("protocol (ii) replay outputs of the models are not on the same windows")
        preds_ii[name] = lab
    if preds_ii:
        rep["protocol_ii"]["bootstrap_all_windows"] = bootstrap_block(y_ii, preds_ii, subj_ii)
    return rep


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="HART WISDM held-out evaluation (two protocols)")
    ap.add_argument("--model", action="append", required=True,
                    help="name=manifest.json,checkpoint_dir (repeatable)")
    ap.add_argument("--eval-data", required=True, help="eval_data.npz (protocol i, test subjects)")
    ap.add_argument("--val-data", required=True, help="val_data.npz (protocol i, temperature fit)")
    ap.add_argument("--wisdm", required=True, help="unpacked wisdm-dataset dir (protocol ii)")
    ap.add_argument("--replay-out", default=None, help="dir for R-format per-window outputs")
    ap.add_argument("--replay-prefix", action="append", default=[],
                    help="name=prefix: write that model's protocol (ii) windows as <prefix>_{val,test}.*")
    ap.add_argument("--reference", action="append", default=[],
                    help="name=npz: check that model's protocol (ii) test windows reproduce an R output")
    ap.add_argument("--out", required=True, help="full JSON report")
    ap.add_argument("--jobs", type=int, default=4)
    from .inertia.integrity import RERUN_REASONS
    ap.add_argument("--ledger", default=HART_LEDGER, help="test ledger (default eval/hart/test_ledger.jsonl)")
    ap.add_argument("--rerun-reason", choices=sorted(RERUN_REASONS))
    ap.add_argument("--rerun-detail", help="free text: what happened and why (required with --rerun-reason)")
    ap.add_argument("--repair-sensitivity", action="store_true",
                    help="G2 E-1/E-3: both protocols with all windows vs excluding repaired windows, + bootstrap CIs "
                         "(protocol ii from the --replay-test outputs; protocol i re-inferred on --eval-data)")
    ap.add_argument("--replay-test", action="append", default=[],
                    help="name=npz,json: a model's protocol (ii) TEST outputs (R format) for --repair-sensitivity")
    ap.add_argument("--repair", default=None, help="loader repair policy of --eval-data (default: wisdm default)")
    ap.add_argument("--record-historical", nargs=2, metavar=("V0_EVAL_NPZ", "V1_EVAL_NPZ"),
                    help="append the two pre-ledger evaluations (labelled historical) to an EMPTY ledger and exit")
    args = ap.parse_args(argv)

    models = {}
    for spec in args.model:
        name, rest = spec.split("=", 1)
        mp, cp = rest.split(",", 1)
        models[name] = (mp, cp)
    prefixes = dict(s.split("=", 1) for s in args.replay_prefix)
    refs = dict(s.split("=", 1) for s in args.reference)
    from .manifest import load_manifest
    if args.record_historical:
        shas = {n: load_manifest(mp).checkpoint["files"]["model.safetensors"]["sha256"] for n, (mp, _) in models.items()}
        k = record_historical(args.ledger, historical_entries(args.record_historical[0], args.record_historical[1],
                                                              shas["v0"], shas["v1"]))
        print(json.dumps({"ledger": args.ledger, "historical_entries": k}))
        return 0
    if args.repair_sensitivity:
        from . import wisdm as W
        replay = {n: tuple(v.split(",", 1)) for n, v in (s.split("=", 1) for s in args.replay_test)}
        repair = args.repair or W.DEFAULT_REPAIR

        def extra():
            return {"replay": replay, "instants": repaired_instants(args.wisdm, TEST_SUBJECTS, repair)}
        vault = _vault(args.eval_data, args.ledger, extra)
        rep = vault.evaluate_once(HART_EXPERIMENT, models_identity(models),
                                  lambda p: repair_sensitivity(models, p, args.jobs), HART_DECLARED,
                                  args.rerun_reason, args.rerun_detail, dataset_splits=dataset_splits(),
                                  history=_ledger_history)
        rep.update({"eval_data": args.eval_data, "repair_policy": repair, "test_subjects": list(TEST_SUBJECTS),
                    "models": {n: {"manifest": mp, "checkpoint": cp} for n, (mp, cp) in models.items()},
                    "replay_test": {n: list(v) for n, v in replay.items()}})
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
        print(json.dumps({"out": args.out, "integrity": rep["integrity"]}))
        return 0
    report: Dict[str, Any] = {"eval_data": args.eval_data, "val_data": args.val_data,
                              "test_subjects": list(TEST_SUBJECTS), "val_subjects": list(VAL_SUBJECTS),
                              "models": {}}
    vault = _vault(args.eval_data, args.ledger)
    report = vault.evaluate_once(HART_EXPERIMENT, models_identity(models),
                                 lambda p: _evaluate_models(models, args, prefixes, refs, report), HART_DECLARED,
                                 args.rerun_reason, args.rerun_detail, dataset_splits=dataset_splits(),
                                 history=_ledger_history)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    summary = os.path.splitext(args.out)[0] + "_summary.json"
    with open(summary, "w", encoding="utf-8") as f:
        json.dump(_strip_reliability(report), f, indent=1,
                  default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    return 0


def _evaluate_models(models, args, prefixes, refs, report) -> Dict[str, Any]:
    """Both protocols for every model (the evaluator of the ledgered full evaluation)."""
    for name, (mp, cp) in models.items():
        print(f"[{name}] protocol (i)", flush=True)
        p1 = protocol_i(name, mp, cp, args.eval_data, args.val_data, args.jobs)
        print(f"[{name}] protocol (ii)", flush=True)
        p2 = protocol_ii(name, mp, cp, args.wisdm, args.jobs)
        docs = p2.pop("_docs")
        entry = {"protocol_i_results_md": p1, "protocol_ii_production_faithful": p2}
        if name in refs:
            entry["reproduces_reference"] = compare_with_reference(docs, refs[name])
        if name in prefixes and args.replay_out:
            entry["replay_outputs"] = write_replay_outputs(docs, mp, args.replay_out, prefixes[name])
        report["models"][name] = entry
        print(json.dumps({"model": name,
                          "i": {k: p1["report"][k] for k in ("n_windows", "coverage", "macro_f1_supported",
                                                             "accepted_precision")},
                          "ii": {k: p2["splits"]["test"][k] for k in ("n_windows", "coverage",
                                                                      "macro_f1_supported",
                                                                      "accepted_precision")},
                          "ref": entry.get("reproduces_reference")}), flush=True)
    return report


if __name__ == "__main__":
    sys.exit(main())
