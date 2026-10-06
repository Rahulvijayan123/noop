"""Nara path vs upstream ``pipelines.general`` on whole recordings (ELDERNET.md §3, §7 parity).

Three steps, two environments (upstream needs its own pinned stack; see ELDERNET.md §8):

    # 1. upstream internals, in the upstream env (PYTHONPATH=<upstream checkout>):
    python -m activity_context.eldernet.parity upstream-dump --input seg.npy --fs 100 --out up.npz
    # 2. the Nara path (serve env):
    python -m activity_context.eldernet.parity nara-dump --input seg.npy --fs 100 --out nara.npz
    # 3. compare (either env); --upstream-csv points at a literal `run --upstream` output dir:
    python -m activity_context.eldernet.parity compare --up up.npz --nara nara.npz [--upstream-csv DIR --nara-csv DIR]

``upstream-dump`` uses upstream's own functions: ``preprocessing.preprocess`` (gravity calibration + actipy
nearest resample; non-wear off below 72 h exactly as ``--nonwear auto``), ``detection.make_windows`` /
``otsu_threshold_log`` / ``run_batch`` (detector logits of every window), and applies
``run_gait_detection``'s rule (variance > min(Otsu, ceiling) and argmax) to those logits — one model pass per
variant (torch 2.0.1 runs ~80 ms/window on this CPU). Variants: calibrated (literal preprocessing) and
uncalibrated (calibration skipped -> isolates torch/numpy numerics). The literal CLI run
(``run --upstream``) is the bit-for-bit reference for bouts and quality.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Dict, Optional, Sequence

import numpy as np

from . import STATIC_VARIANCE_CEILING, WINDOW_S


def _no_nnpack(torch):
    import contextlib
    try:
        import torch.backends.nnpack as nnpack
    except ImportError:                    # torch 2.0.1 (upstream pin) has no switch
        return contextlib.nullcontext()
    return nnpack.flags(enabled=False)


def _softmax1(logits: np.ndarray) -> np.ndarray:
    z = logits[:, 1] - logits[:, 0]
    return 1.0 / (1.0 + np.exp(-z))


def upstream_dump(input_path: str, fs: float, out: str, batch: int = 512) -> None:
    import torch
    from gait_quality import detection, preprocessing
    from gait_quality.config import load_config
    from gait_quality.io import read_recording
    from pipelines.general import load_models
    import actipy.processing as ap
    from pathlib import Path
    torch.set_num_threads(1)
    cfg = load_config(None)
    rec = read_recording(Path(input_path), fs=fs)
    models = load_models(cfg, "cpu")
    res: Dict[str, np.ndarray] = {}
    with _no_nnpack(torch):
        for variant in ("cal", "nocal"):
            if variant == "cal":
                df = preprocessing.preprocess(rec, cfg.pipeline, detect_nonwear=False)
                res["calib_ok"] = np.array(df.attrs.get("CalibOK", -1))
            else:
                df0 = preprocessing.acc_to_dataframe(rec.acc, rec.fs, rec.start_time)
                df, _ = ap.resample(df0, 30)
            acc = df[["x", "y", "z"]].to_numpy()
            win = detection.make_windows(acc, 300, 30)
            var = np.var(win, axis=1).mean(axis=1)
            otsu = detection.otsu_threshold_log(var)
            logits = np.concatenate([detection.run_batch(win[i:i + batch], models["gait_detection"], "cpu")
                                     .reshape(-1, 2) for i in range(0, len(win), batch)])
            # run_gait_detection's rule (detection.py:97-132) applied to these logits: one model pass, not two
            thr = min(otsu, cfg.pipeline.static_variance_ceiling)
            pred = ((var > thr) & (np.argmax(logits, axis=1) == 1)).astype(int)
            res.update({f"{variant}_var": var, f"{variant}_otsu": np.array(otsu), f"{variant}_pred": pred,
                        f"{variant}_logits": logits.astype(np.float64), f"{variant}_n30": np.array(len(acc))})
            if variant == "cal":
                res["cal_acc_head"] = acc[:3000]
    np.savez_compressed(out, **res)


def nara_dump(input_path: str, fs: float, out: str, weights_dir: Optional[str], outdir: Optional[str]) -> None:
    from .model import load_heads
    from .run import analyse, load_array, write_outputs
    from .weights import resolve
    heads = load_heads(resolve(weights_dir))
    acc = load_array(input_path)
    r = analyse(acc, fs, heads, hop_s=1)
    g = r["gait_windows"]
    np.savez_compressed(out, s=np.array([w["s"] for w in g]), gait_prob=np.array([w["gait_prob"] for w in g]),
                        is_gait=np.array([w["is_gait"] for w in g]), prefiltered=np.array([w["prefiltered"] for w in g]),
                        second_labels=r["second_labels"])
    if outdir:
        write_outputs(r, outdir, "seg", input_path)


def _read_csv(path: str):
    import csv
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def compare(up_path: str, nara_path: str, upstream_csv: Optional[str] = None, nara_csv: Optional[str] = None) -> Dict:
    up, na = np.load(up_path), np.load(nara_path)
    n = min(len(up["nocal_logits"]), len(na["gait_prob"]))
    pre_n = na["prefiltered"][:n]
    rep: Dict = {"n_windows": int(n), "calib_ok": int(up["calib_ok"])}
    for variant in ("nocal", "cal"):
        p_up = _softmax1(up[f"{variant}_logits"][:n])
        d = np.abs(p_up - na["gait_prob"][:n])[~pre_n]
        thr = min(float(up[f"{variant}_otsu"]), STATIC_VARIANCE_CEILING)
        pre_up = up[f"{variant}_var"][:n] <= thr
        pred_up = up[f"{variant}_pred"][:n].astype(bool)
        isg = na["is_gait"][:n].astype(bool)
        extra = pre_n & ~pre_up                                    # Nara pre-filters, upstream classifies
        rep[variant] = {
            "max_abs_dprob_classified": float(d.max()) if d.size else 0.0,
            "p99_abs_dprob_classified": float(np.percentile(d, 99)) if d.size else 0.0,
            "otsu_threshold": float(up[f"{variant}_otsu"]), "effective_threshold": thr,
            "n_prefiltered_nara": int(pre_n.sum()), "n_prefiltered_upstream": int(pre_up.sum()),
            "n_nara_only_prefiltered": int(extra.sum()),
            "n_nara_only_prefiltered_upstream_gait": int((extra & pred_up).sum()),
            "n_is_gait_nara": int(isg.sum()), "n_is_gait_upstream": int(pred_up.sum()),
            "n_disagree": int((isg != pred_up).sum()),
            "n_disagree_outside_prefilter_diff": int(((isg != pred_up) & ~extra).sum()),
            "agreement": float((isg == pred_up).mean()),
        }
    if upstream_csv and nara_csv:
        import glob
        import os
        uw = sorted(glob.glob(os.path.join(upstream_csv, "*_windows.csv")))
        nw = os.path.join(nara_csv, "seg_windows.csv")
        su, sn = _read_csv(os.path.join(upstream_csv, "summary.csv"))[0], _read_csv(os.path.join(nara_csv, "summary.csv"))[0]
        rep["bouts"] = {k: {"upstream": float(su[k]), "nara": float(sn[k])}
                        for k in ("walking_time_min", "n_bouts", "n_walking_windows")}
        if uw and os.path.exists(nw):
            a = {r["start_sample"]: r for r in _read_csv(uw[0])}
            b = {r["start_sample"]: r for r in _read_csv(nw)}
            common = sorted(set(a) & set(b), key=int)
            rep["quality_common_windows"] = len(common)
            rep["quality_only_upstream"] = len(set(a) - set(b))
            rep["quality_only_nara"] = len(set(b) - set(a))
            for col in ("gait_speed_m_s", "cadence_steps_min", "stride_length_m", "regularity_eldernet", "step_count"):
                d = [abs(float(a[k][col]) - float(b[k][col])) for k in common]
                rep.setdefault("quality_max_abs_diff", {})[col] = float(max(d)) if d else None
    return rep


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet parity: Nara path vs upstream pipelines.general")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("upstream-dump", "nara-dump"):
        p = sub.add_parser(name)
        p.add_argument("--input", required=True)
        p.add_argument("--fs", type=float, required=True)
        p.add_argument("--out", required=True)
        if name == "nara-dump":
            p.add_argument("--weights-dir", default=None)
            p.add_argument("--csv-dir", default=None)
    c = sub.add_parser("compare")
    c.add_argument("--up", required=True)
    c.add_argument("--nara", required=True)
    c.add_argument("--upstream-csv", default=None)
    c.add_argument("--nara-csv", default=None)
    args = ap.parse_args(argv)
    if args.cmd == "upstream-dump":
        upstream_dump(args.input, args.fs, args.out)
    elif args.cmd == "nara-dump":
        nara_dump(args.input, args.fs, args.out, args.weights_dir, args.csv_dir)
    else:
        print(json.dumps(compare(args.up, args.nara, args.upstream_csv, args.nara_csv), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
