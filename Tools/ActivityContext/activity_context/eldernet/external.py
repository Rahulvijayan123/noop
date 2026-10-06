"""External validation sets (never used for fitting): GOTOV (older adults) and OxWalk (step-annotated).

    python -m activity_context.eldernet.external gotov-extract [--root DIR]     # per-window outputs
    python -m activity_context.eldernet.external gotov-eval                    # once, through the ledger

GOTOV (Paraschiakos et al. 2020; LUMC; CC BY-NC-SA 4.0, accepted by the owner): 35 participants aged 59.5-81.3,
GENEActiv wrist, ~86 Hz (ms timestamps with jitter), in g; protocol activities. This validation-only reader
reads ``Activity_Measurements/GOTOVxx/GOTOVxx-GENEActiv-wrist.csv`` directly (the canonical Inertia loader is
written elsewhere). Truth: walkingSlow / walkingNormal / walkingFast / walkingStairsUp = gait; lying, sitting
(chair / sofa / couch), standing, cycling = non-gait; step, syncJumping, dishwashing, stakingShelves,
vacuumCleaning, NA = masked. Ordinal check: per participant, the median ElderNet speed and cadence over
detected-gait windows of each pace label must satisfy slow < normal < fast.
OxWalk: see :mod:`.oxwalk`.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from typing import Dict, Optional, Sequence

import numpy as np

from .datasets import GAIT, MASK, NON_GAIT, recording_windows, score_recording

GOTOV_DIR_ENV = "GOTOV_DIR"
GOTOV_TRUTH = {"walkingSlow": GAIT, "walkingNormal": GAIT, "walkingFast": GAIT, "walkingStairsUp": GAIT,
               "lyingDownLeft": NON_GAIT, "lyingDownRight": NON_GAIT, "sittingChair": NON_GAIT,
               "sittingSofa": NON_GAIT, "sittingCouch": NON_GAIT, "standing": NON_GAIT, "cycling": NON_GAIT}
PACES = ("walkingSlow", "walkingNormal", "walkingFast")
EXPERIMENT_GOTOV = "eldernet_gotov_external_v1"


def gotov_root(explicit: Optional[str] = None) -> str:
    from ..inertia.paths import har_root, require_dir, under
    return require_dir(explicit or os.environ.get(GOTOV_DIR_ENV, "") or under(har_root(), "gotov"), "GOTOV directory")


def gotov_recording(path: str):
    import pandas as pd
    from ..inertia.datasets import Recording
    df = pd.read_csv(path)
    lab = df["labels"].fillna("NA").astype(str).to_numpy()
    names = sorted(set(lab.tolist()))
    codes = np.searchsorted(np.array(names), lab).astype(np.int32)
    t = df["time"].to_numpy(np.float64) / 1000.0
    xyz = df[["x", "y", "z"]].to_numpy(np.float64)
    ok = np.isfinite(xyz).all(axis=1) & np.isfinite(t)
    pid = os.path.basename(path).split("-")[0]
    return Recording(dataset="gotov", subject=f"gotov:{pid}", session=f"gotov:{pid}:wrist", placement="wrist",
                     device="GENEActiv", wrist_side="unknown", axis_frame="GENEActiv native", source_hz=85.7,
                     t=t[ok], xyz_g=xyz[ok], labels=codes[ok], label_names=names, uniform=False, max_step_s=0.1)


def gotov_extract(work: str, heads, root: Optional[str] = None, hop_s: int = 5) -> int:
    from .extract import part_path
    n = 0
    for path in sorted(glob.glob(os.path.join(gotov_root(root), "Activity_Measurements", "GOTOV*",
                                              "GOTOV*-GENEActiv-wrist.csv"))):
        pid = os.path.basename(path).split("-")[0]
        out = part_path(work, "gotov", "external", pid)
        if os.path.exists(out):
            continue
        rec = gotov_recording(path)
        tt = np.array([GOTOV_TRUTH.get(nm, MASK) for nm in rec.label_names], np.int8)
        ws = recording_windows(rec, tt, hop_s)
        cols = score_recording(heads, ws)
        cols.update(label=np.array(ws.label).astype(str), subject=np.array([rec.subject] * len(ws.s)),
                    session=np.array([rec.session] * len(ws.s)))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        np.savez_compressed(out + ".tmp.npz", **cols)
        os.replace(out + ".tmp.npz", out)
        n += 1
        print(f"[eldernet.external] gotov {pid}: {len(ws.s)} windows", file=sys.stderr, flush=True)
    return n


def load_gotov(work: str) -> Dict[str, np.ndarray]:
    from .extract import load_split_parts
    subs = sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(work, "parts", "gotov", "external", "*.npz")))
    return load_split_parts(work, "gotov", "external", subs)


def ordinal_check(c: Dict[str, np.ndarray], metric: str) -> Dict:
    """Per-participant medians over detected-gait, label-pure windows of each pace; strict ordering test."""
    from scipy.stats import wilcoxon
    pure = c["label_purity"] >= 0.9
    rows = {}
    for subj in np.unique(c["subject"]):
        med = {}
        for pace in PACES:
            m = (c["subject"] == subj) & (c["label"] == pace) & pure & c["is_gait"].astype(bool) & np.isfinite(c[metric])
            med[pace] = float(np.median(c[metric][m])) if m.sum() >= 3 else None
        rows[str(subj)] = med
    full = {s: v for s, v in rows.items() if all(v[p] is not None for p in PACES)}
    order = [v["walkingSlow"] < v["walkingNormal"] < v["walkingFast"] for v in full.values()]
    out = {"n_participants_all_paces": len(full), "n_strictly_ordered": int(sum(order)),
           "frac_strictly_ordered": float(np.mean(order)) if order else None, "per_participant": rows}
    for a, b in (("walkingSlow", "walkingNormal"), ("walkingNormal", "walkingFast")):
        d = np.array([v[b] - v[a] for v in full.values()])
        out[f"{b}_minus_{a}"] = {"median": float(np.median(d)) if len(d) else None,
                                 "frac_positive": float((d > 0).mean()) if len(d) else None,
                                 "wilcoxon_p_one_sided": float(wilcoxon(d, alternative="greater").pvalue)
                                 if len(d) >= 6 else None}
    out["pooled_median"] = {p: float(np.nanmedian([v[p] for v in full.values()])) if full else None for p in PACES}
    return out


def gotov_evaluate(payload: Dict[str, np.ndarray], cal: Dict) -> Dict:
    from .validate import calibrated_prob
    from .vmetrics import auroc_report, binary_report, ece
    c = payload
    m = c["finite"].astype(bool) & ((c["truth"] == GAIT) | (c["truth"] == NON_GAIT))
    y = c["truth"] == GAIT
    p0, pc = c["gait_prob"].astype(float), calibrated_prob(c, float(cal["gait_prob"]["T"]))
    pace_recall = {}
    for lab in PACES + ("walkingStairsUp",):
        mm = m & (c["label"] == lab) & (c["label_purity"] >= 0.9)
        pace_recall[lab] = {"n": int(mm.sum()), "recall_default": float((p0[mm] >= 0.5).mean()) if mm.any() else None,
                            "recall_operating": float((pc[mm] >= cal["gait_threshold"]).mean()) if mm.any() else None}
    return {"upstream_default": binary_report(p0[m], y[m], c["subject"][m], 0.5),
            "calibrated_operating_point": binary_report(pc[m], y[m], c["subject"][m], float(cal["gait_threshold"])),
            "auroc": auroc_report(p0[m], y[m], c["subject"][m]), "ece_uncalibrated": ece(p0[m], y[m]),
            "ece_calibrated": ece(pc[m], y[m]), "recall_by_label": pace_recall,
            "speed_ordinal": ordinal_check(c, "speed_mps"), "cadence_ordinal": ordinal_check(c, "cadence_spm"),
            "n_windows_total": int(len(c["s"])), "n_participants": int(len(np.unique(c["subject"])))}


def gotov_eval(work: str, out_dir: str) -> Dict:
    from .integrity_ext import evaluate_external_once
    return evaluate_external_once(EXPERIMENT_GOTOV, lambda: load_gotov(work), gotov_evaluate, out_dir,
                                  "VALIDATION_GOTOV.json")


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet external validation (GOTOV)")
    ap.add_argument("cmd", choices=("gotov-extract", "gotov-eval"))
    ap.add_argument("--root", default=None)
    ap.add_argument("--work", default=None)
    ap.add_argument("--weights-dir", default=None)
    from .validate import EVAL_DIR
    ap.add_argument("--out", default=EVAL_DIR)
    args = ap.parse_args(argv)
    from .extract import work_dir
    work = work_dir(args.work)
    if args.cmd == "gotov-extract":
        from .model import load_heads
        from .weights import resolve
        gotov_extract(work, load_heads(resolve(args.weights_dir)), args.root)
    else:
        rep = gotov_eval(work, args.out)
        print(json.dumps(rep["upstream_default"], default=float)[:300], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
