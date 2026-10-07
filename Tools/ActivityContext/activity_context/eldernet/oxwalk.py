"""OxWalk external validation: gait detection and step counting against video-annotated heel strikes.

    python -m activity_context.eldernet.oxwalk extract --root <OxWalk_Dec2022 dir>   # per-window outputs
    python -m activity_context.eldernet.oxwalk eval                                  # once, through the ledger

OxWalk (Small, von Fritsch, Doherty, Khalid & Price, University of Oxford, 2022; CC BY 4.0;
doi:10.5287/bodleian:ORQ2abnbR): 39 healthy adults (18+), one hour of unscripted free living each, dominant-wrist
Axivity AX3 at 100 Hz (``Wrist_100Hz/Pxx_wrist100.csv``: ``timestamp,x,y,z,annotation``; calibrated and resampled
by OMGUI, in g; ms timestamps with +-2 ms rounding jitter on an exact 100 Hz grid), every annotated step a single
``1`` at heel strike. Never used for fitting.

Rules (fixed before evaluation):

* windows: the served preprocessing on the uniform 100 Hz array (``preprocess.windows_from_array``, hop 5 s from
  the first sample), the served detector (T = 1, threshold 0.5) and, for ``op``, the VAL calibration;
* ``steps_true`` = annotated heel strikes among the window's 1000 source samples;
* detection truth: gait iff ``steps_true >= 6`` (three strides in 10 s), non-gait iff ``steps_true == 0``,
  1-5 steps masked;
* step agreement on windows that are gait by truth AND detected (``is_gait``): ElderNet ``steps`` (per 10 s) and
  ``cadence_spm`` vs ``steps_true`` and ``6 * steps_true``: bias, MAE, MAPE, Pearson r;
* per-participant totals on the non-overlapping hop-10 subset: predicted = sum of ``steps`` over detected windows,
  true = sum of ``steps_true`` over all its windows; absolute percentage error per participant.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from typing import Dict, Optional, Sequence

import numpy as np

from . import QUALITY_HEADS, WINDOW_S
from .datasets import GAIT, MASK, NON_GAIT
from .gait import score_windows
from .preprocess import stack_windows, windows_from_array

OXWALK_DIR_ENV = "OXWALK_DIR"
EXPERIMENT_OXWALK = "eldernet_oxwalk_external_v1"
GAIT_MIN_STEPS = 6
FS = 100.0


def oxwalk_root(explicit: Optional[str] = None) -> str:
    from ..inertia.paths import har_root, require_dir, under
    return require_dir(explicit or os.environ.get(OXWALK_DIR_ENV, "") or
                       under(har_root(), "oxwalk", "OxWalk_Dec2022"), "OxWalk directory (OxWalk_Dec2022)")


def read_wrist(path: str):
    import pandas as pd
    df = pd.read_csv(path)
    acc = df[["x", "y", "z"]].to_numpy(np.float64)
    ann = df["annotation"].to_numpy()
    if not np.isin(ann, (0, 1)).all():
        raise ValueError(f"{path}: annotation column is not 0/1")
    ts = pd.to_datetime(df["timestamp"])
    t = (ts - ts.iloc[0]).dt.total_seconds().to_numpy()
    if abs(t[-1] - (len(t) - 1) / FS) > 0.05:
        raise ValueError(f"{path}: clock is not a 100 Hz grid ({t[-1]:.3f} s for {len(t)} samples)")
    return acc, ann.astype(np.int8)


def recording_columns(acc: np.ndarray, ann: np.ndarray, heads, hop_s: int = 5) -> Dict[str, np.ndarray]:
    ws = windows_from_array(acc, FS, hop_s=hop_s)
    sc = score_windows(heads, stack_windows(ws))
    rel = np.arange(int(WINDOW_S * FS))
    steps = np.array([int(ann[int(round(w.s * FS)) + rel].sum()) for w in ws], np.int32)
    truth = np.where(steps >= GAIT_MIN_STEPS, GAIT, np.where(steps == 0, NON_GAIT, MASK)).astype(np.int8)
    out = {"s": np.array([w.s for w in ws], np.float64), "steps_true": steps, "truth": truth,
           "prefiltered": sc.prefiltered, "logit_diff": sc.logit_diff, "gait_prob": sc.gait_prob,
           "is_gait": sc.is_gait, "finite": sc.finite}
    for name, (key, _, _, _) in QUALITY_HEADS.items():
        out[key] = sc.metrics[name]
    return out


def extract(work: str, heads, root: Optional[str] = None) -> int:
    from .extract import part_path
    n = 0
    for path in sorted(glob.glob(os.path.join(oxwalk_root(root), "Wrist_100Hz", "P*_wrist100.csv"))):
        pid = os.path.basename(path).split("_")[0]
        out = part_path(work, "oxwalk", "external", pid)
        if os.path.exists(out):
            continue
        acc, ann = read_wrist(path)
        cols = recording_columns(acc, ann, heads)
        cols["subject"] = np.array([f"oxwalk:{pid}"] * len(cols["s"]))
        cols["session"] = np.array([f"oxwalk:{pid}:wrist100"] * len(cols["s"]))
        cols["n_steps_file"] = np.array([int(ann.sum())] * len(cols["s"]), np.int32)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        np.savez_compressed(out + ".tmp.npz", **cols)
        os.replace(out + ".tmp.npz", out)
        n += 1
        print(f"[eldernet.oxwalk] {pid}: {len(cols['s'])} windows", file=sys.stderr, flush=True)
    return n


def load(work: str) -> Dict[str, np.ndarray]:
    from .extract import load_split_parts
    subs = sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(work, "parts", "oxwalk", "external", "*.npz")))
    return load_split_parts(work, "oxwalk", "external", subs)


def _agreement(pred: np.ndarray, true: np.ndarray) -> Dict:
    pred, true = np.asarray(pred, float), np.asarray(true, float)
    if not len(pred):
        return {"n": 0}
    d = pred - true
    with np.errstate(divide="ignore", invalid="ignore"):
        ape = np.abs(d) / true
    r = float(np.corrcoef(pred, true)[0, 1]) if len(pred) > 2 and pred.std() > 0 and true.std() > 0 else None
    return {"n": int(len(pred)), "bias": float(d.mean()), "mae": float(np.abs(d).mean()),
            "mape": float(np.mean(ape[np.isfinite(ape)])), "pearson_r": r,
            "true_mean": float(true.mean()), "pred_mean": float(pred.mean()),
            "loa95": [float(d.mean() - 1.96 * d.std(ddof=1)), float(d.mean() + 1.96 * d.std(ddof=1))] if len(d) > 1 else None}


def evaluate(c: Dict[str, np.ndarray], cal: Dict) -> Dict:
    from .validate import calibrated_prob
    from .vmetrics import auroc_report, binary_report, ece
    fin = c["finite"].astype(bool)
    m = fin & ((c["truth"] == GAIT) | (c["truth"] == NON_GAIT))
    y = c["truth"] == GAIT
    p0, pc = c["gait_prob"].astype(float), calibrated_prob(c, float(cal["gait_prob"]["T"]))
    det = fin & c["is_gait"].astype(bool)
    both = det & y
    steps_true = c["steps_true"].astype(float)
    hop10 = np.isclose(np.mod(c["s"], 10.0), 0.0)
    totals = {}
    for subj in np.unique(c["subject"]):
        k = (c["subject"] == subj) & hop10
        pred = float(np.nansum(np.where(det[k], c["steps"][k], 0.0)))
        true = float(steps_true[k].sum())
        totals[str(subj)] = {"true": true, "pred": pred, "ape": abs(pred - true) / true if true else None,
                             "file_steps": int(c["n_steps_file"][k][0]) if k.any() else None}
    apes = np.array([v["ape"] for v in totals.values() if v["ape"] is not None])
    return {"upstream_default": binary_report(p0[m], y[m], c["subject"][m], 0.5),
            "calibrated_operating_point": binary_report(pc[m], y[m], c["subject"][m], float(cal["gait_threshold"])),
            "auroc": auroc_report(p0[m], y[m], c["subject"][m]), "ece_uncalibrated": ece(p0[m], y[m]),
            "ece_calibrated": ece(pc[m], y[m]),
            "n_windows_total": int(len(c["s"])), "n_masked_1_to_5_steps": int((c["truth"] == MASK).sum()),
            "steps_per_window": _agreement(c["steps"][both], steps_true[both]),
            "cadence_spm": _agreement(c["cadence_spm"][both], 6.0 * steps_true[both]),
            "detected_windows_with_0_true_steps": {"n": int((det & (steps_true == 0)).sum()),
                                                   "mean_pred_steps": float(np.nanmean(c["steps"][det & (steps_true == 0)]))
                                                   if (det & (steps_true == 0)).any() else None},
            "participant_totals": {"median_ape": float(np.median(apes)) if len(apes) else None,
                                   "mean_ape": float(np.mean(apes)) if len(apes) else None,
                                   "sum_true": float(sum(v["true"] for v in totals.values())),
                                   "sum_pred": float(sum(v["pred"] for v in totals.values())),
                                   "per_participant": totals},
            "rules": {"gait_min_steps": GAIT_MIN_STEPS, "non_gait_steps": 0, "hop_s": 5, "totals_hop_s": 10}}


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet external validation (OxWalk)")
    ap.add_argument("cmd", choices=("extract", "eval"))
    ap.add_argument("--root", default=None)
    ap.add_argument("--work", default=None)
    ap.add_argument("--weights-dir", default=None)
    from .validate import EVAL_DIR
    ap.add_argument("--out", default=EVAL_DIR)
    args = ap.parse_args(argv)
    from .extract import work_dir
    work = work_dir(args.work)
    if args.cmd == "extract":
        from .model import load_heads
        from .weights import resolve
        extract(work, load_heads(resolve(args.weights_dir)), args.root)
    else:
        from .integrity_ext import evaluate_external_once
        rep = evaluate_external_once(EXPERIMENT_OXWALK, lambda: load(work), evaluate, args.out, "VALIDATION_OXWALK.json")
        print(json.dumps(rep["upstream_default"], default=float)[:300], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
