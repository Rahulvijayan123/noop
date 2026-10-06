"""ElderNet validation on the frozen subject splits — weights frozen, VAL-only calibration, TEST once.

    python -m activity_context.eldernet.validate fit   [--work DIR]   # VAL -> eval/eldernet/calibration.json
    python -m activity_context.eldernet.validate test  [--work DIR]   # TEST through the ledger -> VALIDATION.json
    python -m activity_context.eldernet.validate prior [--work DIR] [--write]          # VAL: decoder pi
    python -m activity_context.eldernet.validate other-motion [--work DIR] [--write]   # VAL: running / cycling / vehicle

Inputs are the per-window outputs of :mod:`.extract` (served detector, hop 5 s). Truth: walking / stairs = gait,
stationary / cycling / vehicle = non-gait (crosswalk; ``datasets.py``), running reported separately, the rest
masked. A pre-filtered window keeps ``gait_prob`` 0 under any calibration (as served).

``fit`` (VAL subjects only): temperature T on the detector's logit gap by NLL over the FREE-LIVING VAL windows
(Capture-24 — the only free-living wrist set, i.e. the WHOOP use case); then the operating threshold through ``inertia.abstention.select_operating_point`` (target precision
0.95, subject-cluster bootstrap q05, stability above tau) on the pooled VAL windows (free-living Capture-24
dominates them, as WHOOP data would). ``test`` opens the TEST payload only inside an
``inertia.integrity.TestVault`` whose ledger is ``eval/eldernet/test_ledger.jsonl``; the experiment is spent
(``integrity_ext.SPENT_EXPERIMENTS``), so it refuses without an enumerated rerun reason.

``prior`` and ``other-motion`` read VAL parts only (``--write`` merges them into ``VALIDATION.json``):
the decoder prior pi that makes the gait channel mean-neutral over the windows the decoder sees (mean served
gait_prob over every Capture-24 VAL window, unlabelled and pre-filtered included), and the served gait_prob
distribution on running / jogging, cycling and vehicle windows (for the decoder's gait-row compat).
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
    from .integrity_ext import SPENT_EXPERIMENTS, spent_rerun_detail
    rerun_detail = spent_rerun_detail(EXPERIMENT, rerun_reason, rerun_detail)    # spent: refuse before loading
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
                "upstream_commit": UPSTREAM_COMMIT, "spent_before": SPENT_EXPERIMENTS.get(EXPERIMENT)})
    with open(os.path.join(out_dir, "VALIDATION_TEST.json"), "w") as f:
        json.dump(rep, f, indent=1, sort_keys=True, default=float)
        f.write("\n")
    return rep


# ---------------------------------------------------------------------------
# VAL-only measurements for the decoder (no fitting, no TEST)
# ---------------------------------------------------------------------------

LABELLED_PI = 0.065            # ELDERNET.md §8 before 2026-10-06: gait share of labelled Capture-24 VAL windows


def _cluster_mean_ci(q: np.ndarray, subj: np.ndarray, n_boot: int = 2000, seed: int = 0):
    """Subject-cluster bootstrap 95 % CI of the window-pooled mean."""
    us = np.unique(subj)
    sums = np.array([q[subj == u].sum() for u in us])
    ns = np.array([(subj == u).sum() for u in us], float)
    rng = np.random.default_rng(seed)
    k = rng.integers(0, len(us), (n_boot, len(us)))
    b = sums[k].sum(axis=1) / ns[k].sum(axis=1)
    return [float(np.quantile(b, 0.025)), float(np.quantile(b, 0.975))]


def decoder_prior(val: Dict[str, Dict[str, np.ndarray]]) -> Dict:
    """pi = E[gait_prob] over every Capture-24 VAL window the served path emits (hop 5): then E[q / pi] =
    E[(1 - q) / (1 - pi)] = 1 and the decoder's gait term is mean-neutral on the windows it actually sees
    (pre-filtered windows carry q = 0 on the wire; unlabelled stretches are worn time too)."""
    c = val["capture24"]
    fin = c["finite"].astype(bool)
    q, t = c["gait_prob"].astype(float)[fin], c["truth"][fin]
    pre, subj, lab = c["prefiltered"].astype(bool)[fin], c["subject"][fin], c["label"].astype(str)[fin]
    scored = (t == GAIT) | (t == NON_GAIT)
    unlabelled = lab == "<NA>"
    per_subject = np.array([q[subj == u].mean() for u in np.unique(subj)])
    groups = {"all_windows": np.ones(len(q), bool), "labelled_gait_or_non_gait": scored,
              "labelled_masked": ~scored & ~unlabelled, "unlabelled": unlabelled,
              "not_prefiltered": ~pre, "prefiltered": pre}
    pi = float(q.mean())
    return {
        "split": "val", "dataset": "capture24", "hop_s": 5, "n_subjects": int(len(per_subject)),
        "n_windows": int(len(q)), "recommended_pi": round(pi, 3), "mean_gait_prob_all_windows": pi,
        "ci95_subject_bootstrap": _cluster_mean_ci(q, subj),
        "per_subject_mean": {"min": float(per_subject.min()), "median": float(np.median(per_subject)),
                             "max": float(per_subject.max())},
        "labelled_gait_prevalence": float((t[scored] == GAIT).mean()), "previous_pi": LABELLED_PI,
        "mean_q_over_previous_pi": pi / LABELLED_PI,
        "groups": {k: {"n": int(m.sum()), "frac_of_windows": float(m.mean()), "mean_gait_prob": float(q[m].mean()),
                       "frac_prefiltered": float(pre[m].mean())} for k, m in groups.items()},
        "why": "pi equal to the mean served gait_prob over all windows makes E[q/pi] = E[(1-q)/(1-pi)] = 1, so the "
               "gait channel adds no net pull on average; the labelled-window prevalence leaves out the unlabelled "
               "and masked windows the decoder also sees, and with it E[q/pi] = mean_q_over_previous_pi (> 1: a "
               "standing pull toward gait)",
    }


def _dist(q: np.ndarray, pre: np.ndarray, subj: np.ndarray, pi: float) -> Dict:
    if not len(q):
        return {"n": 0}
    p = np.quantile(q, [0.1, 0.25, 0.5, 0.75, 0.9])
    return {"n": int(len(q)), "n_subjects": int(len(np.unique(subj))), "mean": float(q.mean()),
            "p10": float(p[0]), "p25": float(p[1]), "median": float(p[2]), "p75": float(p[3]), "p90": float(p[4]),
            "frac_is_gait_0.5": float((q >= 0.5).mean()), "frac_ge_0.93": float((q >= 0.93).mean()),
            "frac_prefiltered": float(pre.mean()), "frac_q_above_pi": float((q > pi).mean()),
            "mean_q_over_pi": float((q / pi).mean())}


def other_motion(val: Dict[str, Dict[str, np.ndarray]], pi: float) -> Dict:
    """Served gait_prob on VAL windows of running / jogging (truth RUNNING, >= 90 % pure), cycling and vehicle
    (truth NON_GAIT whose majority label maps to exactly that locomotion class), with walking and stationary for
    reference; per dataset (running by source label) and pooled."""
    from ..inertia.mappings import load_mappings
    from .datasets import _BIT
    cw = load_mappings()
    out: Dict = {"split": "val", "pi": pi, "datasets": {}, "pooled": {}}
    pooled: Dict[str, list] = {}
    for d, c in val.items():
        fin = c["finite"].astype(bool)
        lab, t = c["label"].astype(str), c["truth"]
        q, pre, subj = c["gait_prob"].astype(float), c["prefiltered"].astype(bool), c["subject"]
        masks = {L: (cw.class_target(d, L, "locomotion") if cw.has_label(d, L) else 0) for L in np.unique(lab)}
        mk = np.array([masks[L] for L in lab], dtype=np.int64) if len(lab) else np.zeros(0, np.int64)
        sel = {"running": fin & (t == RUNNING),
               "cycling": fin & (t == NON_GAIT) & (mk == _BIT["cycling"]),
               "vehicle": fin & (t == NON_GAIT) & (mk == _BIT["vehicle_motion"]),
               "walking_gait_reference": fin & (t == GAIT),
               "stationary_reference": fin & (t == NON_GAIT) & (mk == _BIT["stationary"])}
        rep = {}
        for g, m in sel.items():
            if not m.any():
                continue
            rep[g] = _dist(q[m], pre[m], subj[m], pi)
            pooled.setdefault(g, []).append((q[m], pre[m], subj[m]))
        if sel["running"].any():
            rep["running_by_label"] = {L: _dist(q[sel["running"] & (lab == L)], pre[sel["running"] & (lab == L)],
                                                subj[sel["running"] & (lab == L)], pi)
                                       for L in np.unique(lab[sel["running"]])}
        out["datasets"][d] = rep
    for g, parts in pooled.items():
        out["pooled"][g] = _dist(*(np.concatenate([p[i] for p in parts]) for i in range(3)), pi)
    return out


def write_validation_key(key: str, value: Dict, out_dir: str = EVAL_DIR) -> None:
    """Merge one VAL-only section into VALIDATION.json (its format: indent 1, sorted keys, no final newline)."""
    path = os.path.join(out_dir, "VALIDATION.json")
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    doc[key] = value
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, indent=1, sort_keys=True, default=float))


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet frozen-split validation (VAL fit, TEST once)")
    ap.add_argument("cmd", choices=("fit", "test", "prior", "other-motion"))
    ap.add_argument("--work", default=None)
    ap.add_argument("--out", default=EVAL_DIR)
    ap.add_argument("--rerun-reason", default=None)
    ap.add_argument("--rerun-detail", default=None)
    ap.add_argument("--write", action="store_true", help="prior / other-motion: merge into VALIDATION.json")
    args = ap.parse_args(argv)
    from .extract import work_dir
    work = work_dir(args.work)
    if args.cmd == "fit":
        doc = fit(work, args.out)
        print(json.dumps({k: doc[k] for k in ("calibration_id", "gait_prob", "gait_threshold")}), file=sys.stderr)
    elif args.cmd in ("prior", "other-motion"):
        val = load_split(work, "val")
        prior = decoder_prior(val)
        if args.cmd == "prior":
            key, rep = "decoder_prior", prior
        else:
            key, rep = "val_other_motion", other_motion(val, prior["recommended_pi"])
        if args.write:
            write_validation_key(key, rep, args.out)
        print(json.dumps(rep, indent=1, default=float))
    else:
        rep = test(work, args.out, args.rerun_reason, args.rerun_detail)
        print(json.dumps(rep["pooled"]["upstream_default"], default=float)[:400], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
