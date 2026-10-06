"""ElderNet validation on the frozen subject splits — weights frozen, VAL-only calibration, TEST once.

    python -m activity_context.eldernet.validate fit   [--work DIR]   # VAL -> eval/eldernet/calibration.json
    python -m activity_context.eldernet.validate test  [--work DIR]   # TEST through the ledger -> VALIDATION.json

Inputs are the per-window outputs of :mod:`.extract` (served detector, hop 5 s). Truth: walking / stairs = gait,
stationary / cycling / vehicle = non-gait (crosswalk; ``datasets.py``), running reported separately, the rest
masked. A pre-filtered window keeps ``gait_prob`` 0 under any calibration (as served).

``fit`` (VAL subjects only): temperature T on the detector's logit gap by NLL over the FREE-LIVING VAL windows
(Capture-24 — the only free-living wrist set, i.e. the WHOOP use case); then the operating threshold through ``inertia.abstention.select_operating_point`` (target precision
0.95, subject-cluster bootstrap q05, stability above tau) on the pooled VAL windows (free-living Capture-24
dominates them, as WHOOP data would). ``test`` opens the TEST payload only inside an
``inertia.integrity.TestVault`` whose ledger is ``eval/eldernet/test_ledger.jsonl``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from typing import Dict, Optional, Sequence

import numpy as np

from . import MODEL_VERSION, PREPROCESSING_VERSION, UPSTREAM_COMMIT
from .datasets import GAIT, NON_GAIT, RUNNING
from .gait import CALIBRATION_SCHEMA

DATASETS = ("wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "capture24")
EVAL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "eval", "eldernet")
EXPERIMENT = "eldernet_frozen_detection_v1"
DECLARED = (EXPERIMENT,)
FREE_LIVING = ("capture24",)
# Rule history (VAL only, before TEST was opened): weighting all six VAL datasets equally gave T = 0.557, which
# sharpened the five well-separated lab sets but tripled free-living ECE (Capture-24 VAL 0.008 -> 0.026);
# replaced by the free-living fit (T ~ 1.05, Capture-24 VAL ECE 0.008).
REJECTED_RULES = [{"rule": "temperature NLL, each VAL dataset weight 1", "T": 0.557066,
                   "capture24_val_ece": 0.026, "reason": "worsened free-living calibration; lab sets dominated"}]


def load_split(work: str, split: str, datasets: Sequence[str] = DATASETS) -> Dict[str, Dict[str, np.ndarray]]:
    from .extract import load_split_parts, split_subjects
    return {d: load_split_parts(work, d, split, split_subjects(d, split)) for d in datasets}


def calibrated_prob(cols: Dict[str, np.ndarray], T: float) -> np.ndarray:
    z = np.nan_to_num(cols["logit_diff"].astype(float), nan=0.0)
    p = 1.0 / (1.0 + np.exp(-np.clip(z / T, -60, 60)))
    return np.where(cols["prefiltered"].astype(bool), 0.0, p)


def _scored(cols: Dict[str, np.ndarray]) -> np.ndarray:
    t = cols["truth"]
    return cols["finite"].astype(bool) & ((t == GAIT) | (t == NON_GAIT))


def split_sha256(data: Dict[str, Dict[str, np.ndarray]]) -> str:
    h = hashlib.sha256()
    for d in sorted(data):
        c = data[d]
        for k in ("subject", "session"):
            h.update("\n".join(c[k].astype(str).tolist()).encode())
        h.update(np.ascontiguousarray(c["s"], np.float64).tobytes())
    return h.hexdigest()


def fit_temperature(z: np.ndarray, y: np.ndarray, w: np.ndarray) -> float:
    from scipy.optimize import minimize_scalar

    def nll(logT):
        s = z / np.exp(logT)
        return float(np.sum(w * (np.logaddexp(0, s) - y * s)) / np.sum(w))
    r = minimize_scalar(nll, bounds=(np.log(0.05), np.log(20.0)), method="bounded", options={"xatol": 1e-6})
    return float(np.exp(r.x))


def fit(work: str, out_dir: str = EVAL_DIR) -> Dict:
    from ..inertia.abstention import select_operating_point
    val = load_split(work, "val")
    zs, ys, ws, ps, subs = [], [], [], [], []
    for d, c in val.items():
        if d not in FREE_LIVING:
            continue
        m = _scored(c)
        clf = m & ~c["prefiltered"].astype(bool)
        if clf.any():
            zs.append(c["logit_diff"][clf])
            ys.append((c["truth"][clf] == GAIT).astype(float))
            ws.append(np.ones(int(clf.sum())))
    T = fit_temperature(np.concatenate(zs), np.concatenate(ys), np.concatenate(ws))
    for d, c in val.items():
        m = _scored(c)
        ps.append(calibrated_prob(c, T)[m])
        subs.append(c["subject"][m])
    p = np.concatenate(ps)
    y = np.concatenate([(val[d]["truth"][_scored(val[d])] == GAIT) for d in val])
    probs = np.stack([1 - p, p], axis=1)
    truth = np.stack([~y, y], axis=1)
    op = select_operating_point(probs, truth, np.concatenate(subs), 1, True)
    tau = float(op["tau"]) if op["status"] != "abstain" else 0.5
    doc = {"schema": CALIBRATION_SCHEMA, "calibration_id": f"eldernet-val-T{T:.4f}-tau{tau:.3f}",
           "gait_prob": {"method": "temperature", "T": round(T, 6), "fit": "val"},
           "gait_threshold": tau, "operating_point": {k: v for k, v in op.items() if k != "evidence"},
           "operating_point_evidence": op.get("evidence"),
           "fit": {"split": "val", "val_split_sha256": split_sha256(val), "datasets": list(val),
                   "n_val_scored": int(len(y)), "n_val_gait": int(y.sum()),
                   "temperature_fit_datasets": [d for d in val if d in FREE_LIVING],
                   "temperature_weighting": "every classified (not pre-filtered) free-living VAL window weight 1",
                   "threshold_fit_datasets": list(val), "rejected_rules": REJECTED_RULES},
           "model_version": MODEL_VERSION, "upstream_commit": UPSTREAM_COMMIT,
           "preprocessing_version": PREPROCESSING_VERSION}
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "calibration.json"), "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True, default=float)
        f.write("\n")
    return doc


def evaluate_payload(test: Dict[str, Dict[str, np.ndarray]], cal: Dict) -> Dict:
    from .vmetrics import auroc_report, binary_report, ece, risk_coverage_summary
    T, tau = float(cal["gait_prob"]["T"]), float(cal["gait_threshold"])
    out: Dict = {"datasets": {}}
    pooled = {k: [] for k in ("p0", "pc", "y", "subj", "ds")}
    for d, c in test.items():
        m = _scored(c)
        p0, pc = c["gait_prob"].astype(float), calibrated_prob(c, T)
        y = c["truth"] == GAIT
        run = c["finite"].astype(bool) & (c["truth"] == RUNNING)
        r = {"n_windows_total": int(len(c["s"])), "n_masked": int((~m & ~run).sum()), "n_running": int(run.sum()),
             "n_prefiltered": int(c["prefiltered"].astype(bool).sum()),
             "upstream_default": binary_report(p0[m], y[m], c["subject"][m], 0.5),
             "calibrated_operating_point": binary_report(pc[m], y[m], c["subject"][m], tau),
             "auroc": auroc_report(p0[m], y[m], c["subject"][m]) if y[m].any() and (~y[m]).any() else None,
             "ece_uncalibrated": ece(p0[m], y[m]), "ece_calibrated": ece(pc[m], y[m]),
             "risk_coverage_default": risk_coverage_summary(p0[m], y[m], 0.5),
             "running": {"n": int(run.sum()), "frac_is_gait_default": float((p0[run] >= 0.5).mean()) if run.any() else None,
                         "frac_is_gait_operating": float((pc[run] >= tau).mean()) if run.any() else None,
                         "mean_gait_prob": float(p0[run].mean()) if run.any() else None}}
        out["datasets"][d] = r
        for k, v in (("p0", p0[m]), ("pc", pc[m]), ("y", y[m]), ("subj", c["subject"][m]),
                     ("ds", np.array([d] * int(m.sum())))):
            pooled[k].append(v)
    P = {k: np.concatenate(v) for k, v in pooled.items()}
    out["pooled"] = {"upstream_default": binary_report(P["p0"], P["y"], P["subj"], 0.5, strata=P["ds"]),
                     "calibrated_operating_point": binary_report(P["pc"], P["y"], P["subj"], tau, strata=P["ds"]),
                     "auroc": auroc_report(P["p0"], P["y"], P["subj"], strata=P["ds"]),
                     "ece_uncalibrated": ece(P["p0"], P["y"]), "ece_calibrated": ece(P["pc"], P["y"]),
                     "risk_coverage_default": risk_coverage_summary(P["p0"], P["y"], 0.5)}
    lab = [d for d in test if d != "capture24"]
    out["macro_over_datasets"] = {
        f"{k}_{s}": float(np.nanmean([out["datasets"][d][s][k] for d in test]))
        for s in ("upstream_default", "calibrated_operating_point") for k in ("precision", "recall", "f1")}
    out["lab_datasets"] = lab
    return out


def test(work: str, out_dir: str = EVAL_DIR, rerun_reason: Optional[str] = None, rerun_detail: Optional[str] = None) -> Dict:
    from ..inertia.integrity import SplitLeakError, TestVault
    with open(os.path.join(out_dir, "calibration.json")) as f:
        cal = json.load(f)
    if cal["gait_prob"].get("fit") != "val" or cal["fit"].get("split") != "val":
        raise SplitLeakError("calibration must be fitted on VAL")

    def identity(payload):
        return (np.array([split_sha256(payload)]),)

    def before(test_sha):
        if test_sha == cal["fit"]["val_split_sha256"]:
            raise SplitLeakError("calibration VAL hash equals the TEST hash")

    vault = TestVault(lambda: load_split(work, "test"), identity, os.path.join(out_dir, "test_ledger.jsonl"))
    cal_sha = hashlib.sha256(json.dumps(cal, sort_keys=True).encode()).hexdigest()
    rep = vault.evaluate_once(EXPERIMENT, f"{MODEL_VERSION}+cal:{cal_sha[:16]}",
                              lambda payload: evaluate_payload(payload, cal), DECLARED,
                              rerun_reason=rerun_reason, rerun_detail=rerun_detail, before=before)
    rep.update({"calibration": {k: cal[k] for k in ("calibration_id", "gait_prob", "gait_threshold")},
                "model_version": MODEL_VERSION, "preprocessing_version": PREPROCESSING_VERSION,
                "upstream_commit": UPSTREAM_COMMIT})
    with open(os.path.join(out_dir, "VALIDATION_TEST.json"), "w") as f:
        json.dump(rep, f, indent=1, sort_keys=True, default=float)
        f.write("\n")
    return rep


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet frozen-split validation (VAL fit, TEST once)")
    ap.add_argument("cmd", choices=("fit", "test"))
    ap.add_argument("--work", default=None)
    ap.add_argument("--out", default=EVAL_DIR)
    ap.add_argument("--rerun-reason", default=None)
    ap.add_argument("--rerun-detail", default=None)
    args = ap.parse_args(argv)
    from .extract import work_dir
    work = work_dir(args.work)
    if args.cmd == "fit":
        doc = fit(work, args.out)
        print(json.dumps({k: doc[k] for k in ("calibration_id", "gait_prob", "gait_threshold")}), file=sys.stderr)
    else:
        rep = test(work, args.out, args.rerun_reason, args.rerun_detail)
        print(json.dumps(rep["pooled"]["upstream_default"], default=float)[:400], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
