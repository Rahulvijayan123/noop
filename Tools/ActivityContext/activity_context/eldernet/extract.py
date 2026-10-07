"""Per-window ElderNet outputs for the frozen VAL / TEST subjects (offline; ELDERNET.md §7).

    python -m activity_context.eldernet.extract --dataset capture24 --split test [--subjects P102 P103 ...]
        [--hop-s 5] [--work DIR] [--weights-dir DIR]

One ``parts/<dataset>/<split>/<subject>.npz`` per subject (so several processes can split a dataset), holding
raw columns (:data:`datasets.COLUMNS` + subject / session / label) — nothing here looks at metrics; TEST
truth is only scored by ``validate.py test`` through the ledger. Paths: ``--work`` or
``$ELDERNET_WORK_DIR`` or ``$INERTIA_DATA_ROOT/eldernet-work``.

Capture-24 (100 Hz, in g) goes through the SERVE path: each run is quantised to WHOOP NPB1 i16 columns
(1/4096 g, gyro zero) and fed hour by hour to ``runtime.score_request_seconds`` (the code behind every
``infer``; chunks overlap by 10 s, a window belongs to the chunk it starts in). Its wire windows are also the
replay rows. Other datasets (20-200 Hz, irregular clocks) cannot be NPB1 and use
:func:`datasets.recording_windows` + the same :func:`gait.score_windows`.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sys
from typing import Dict, List, Optional, Sequence

import numpy as np

from . import QUALITY_HEADS, WINDOW_S
from .datasets import MASK, PURITY, recording_windows, score_recording, split_runs, truth_table
from .gait import wire_windows
from .preprocess import window_indices

CHUNK_S = 3600
SPLIT_KEYS = {"val": "val_subjects", "test": "test_subjects", "train": "train_subjects"}


def work_dir(explicit: Optional[str] = None) -> str:
    from ..inertia.paths import data_root, require_dir, under
    return require_dir(explicit or os.environ.get("ELDERNET_WORK_DIR", "") or under(data_root(), "eldernet-work"),
                       "ElderNet work directory ($ELDERNET_WORK_DIR or $INERTIA_DATA_ROOT)")


def split_subjects(dataset: str, split: str) -> List[str]:
    from ..inertia.splits import load_split
    return [str(s) for s in load_split(dataset)[SPLIT_KEYS[split]]]


def _window_truth(cat: np.ndarray):
    vals, cnt = np.unique(cat, return_counts=True)
    j = int(np.argmax(cnt))
    pur = float(cnt[j]) / len(cat)
    return (int(vals[j]) if pur >= PURITY else MASK), pur


def runtime_recording(rt, rec, truth_codes: np.ndarray, hop_s: int):
    """Capture-24 recording -> (column dict, wire rows) through runtime.score_request_seconds."""
    from .runtime import score_request_seconds
    cols: Dict[str, list] = {k: [] for k in ("s", "purity", "truth", "label", "prefiltered", "logit_diff",
                                              "gait_prob", "is_gait", "finite")}
    metrics: Dict[str, list] = {v[0]: [] for v in QUALITY_HEADS.values()}
    wire: List[Dict] = []
    rel = window_indices(0, 100)
    for sl in split_runs(rec.t, rec.split_step_s, rec.filled):
        t, x, codes = rec.t[sl], rec.xyz_g[sl], rec.labels[sl]
        n_sec = len(t) // 100
        if n_sec < WINDOW_S:
            continue
        start = int(np.floor(t[0]))
        offset = float(t[0] - start)
        q = np.clip(np.rint(x[:n_sec * 100] * 4096.0), -32768, 32767).astype(np.int16)
        blk = q.reshape(n_sec, 100, 3).transpose(0, 2, 1).reshape(n_sec, 300)
        colsec = np.concatenate([blk, np.zeros((n_sec, 300), np.int16)], axis=1)
        for a in range(0, n_sec, CHUNK_S):
            b = min(n_sec, a + CHUNK_S + WINDOW_S)
            secs = [(start + k, colsec[k]) for k in range(a, b)]
            windows, sc = score_request_seconds(rt, secs, start + a, start + b, hop_s)
            keep = [i for i, w in enumerate(windows) if w.s < start + a + CHUNK_S]
            if not keep:
                continue
            ws = [windows[i] for i in keep]
            sub = type(sc)(**{f: (v[keep] if isinstance(v, np.ndarray) else {k: m[keep] for k, m in v.items()})
                              for f, v in sc.__dict__.items()})
            items, _ = wire_windows(ws, sub)
            for it in items:
                wire.append(dict(it, s=it["s"] + offset, e=it["e"] + offset, subject=rec.subject, session=rec.session))
            for j, w in enumerate(ws):
                src = (w.s - start) * 100 + rel
                tr, pur = _window_truth(truth_codes[codes[src]])
                lab_vals, lab_cnt = np.unique(codes[src], return_counts=True)
                cols["s"].append(w.s + offset)
                cols["purity"].append(pur)
                cols["truth"].append(tr)
                cols["label"].append(rec.label_names[int(lab_vals[int(np.argmax(lab_cnt))])])
                for k in ("prefiltered", "logit_diff", "gait_prob", "is_gait", "finite"):
                    cols[k].append(getattr(sub, k)[j])
                for name, (key, _, _, _) in QUALITY_HEADS.items():
                    metrics[key].append(sub.metrics[name][j])
    out = {k: np.array(v) for k, v in cols.items()}
    out.update({k: np.array(v, np.float64) for k, v in metrics.items()})
    out["e"] = out["s"] + WINDOW_S if len(out["s"]) else np.zeros(0)
    return out, wire


def extract_subject(dataset: str, subject: str, heads, hop_s: int, cw) -> Dict:
    from .runtime import build_runtime
    from .datasets import iter_split_recordings
    parts, wire = [], []
    for rec in iter_split_recordings(dataset, [subject]):
        tt = truth_table(cw, dataset, rec.label_names)
        if dataset == "capture24":
            cols, w = runtime_recording(build_runtime(heads=heads), rec, tt, hop_s)
            wire += w
        else:
            ws = recording_windows(rec, tt, hop_s)
            cols = score_recording(heads, ws)
            cols["label"] = np.array(ws.label)
            if dataset == "wisdm2019_watch":
                from .preprocess import GaitWindow
                from .gait import WindowScores
                sc = WindowScores(prefiltered=cols["prefiltered"], logit_diff=cols["logit_diff"],
                                  gait_prob=cols["gait_prob"], is_gait=cols["is_gait"], finite=cols["finite"],
                                  metrics={n: cols[v[0]] for n, v in QUALITY_HEADS.items()})
                items, _ = wire_windows([GaitWindow(s=float(s), e=float(s) + WINDOW_S, data=None) for s in ws.s], sc)
                wire += [dict(it, subject=rec.subject, session=rec.session) for it in items]
        n = len(cols["s"])
        cols["session"] = np.array([rec.session] * n)
        cols["placement"] = np.array([rec.placement] * n)
        parts.append(cols)
    keys = sorted({k for p in parts for k in p})
    merged = {k: np.concatenate([p[k] for p in parts if k in p]) if parts else np.zeros(0) for k in keys}
    merged["subject"] = np.array([f"{dataset}:{subject}"] * len(merged.get("s", [])))
    return {"cols": merged, "wire": wire}


def part_path(work: str, dataset: str, split: str, subject: str) -> str:
    return os.path.join(work, "parts", dataset, split, f"{subject}.npz")


def load_split_parts(work: str, dataset: str, split: str, subjects: Sequence[str]) -> Dict[str, np.ndarray]:
    parts = []
    for s in subjects:
        p = part_path(work, dataset, split, s)
        if not os.path.exists(p):
            raise FileNotFoundError(f"missing extraction part {p}; run activity_context.eldernet.extract")
        with np.load(p, allow_pickle=False) as z:
            parts.append({k: z[k] for k in z.files})
    keys = sorted({k for p in parts for k in p})
    return {k: np.concatenate([p[k] for p in parts if k in p and len(p[k]) == len(p["s"])]) for k in keys}


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Extract per-window ElderNet outputs for frozen split subjects")
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--split", required=True, choices=sorted(SPLIT_KEYS))
    ap.add_argument("--subjects", nargs="*", default=None)
    ap.add_argument("--hop-s", type=int, default=5)
    ap.add_argument("--work", default=None)
    ap.add_argument("--weights-dir", default=None)
    ap.add_argument("--replay-dir", default=None, help="also write wire rows (*.jsonl.gz) here (replay sets)")
    args = ap.parse_args(argv)
    from ..inertia.mappings import load_mappings
    from .model import load_heads
    from .weights import resolve
    work = work_dir(args.work)
    heads = load_heads(resolve(args.weights_dir))
    cw = load_mappings()
    for subj in (args.subjects or split_subjects(args.dataset, args.split)):
        out = part_path(work, args.dataset, args.split, subj)
        if os.path.exists(out):
            continue
        res = extract_subject(args.dataset, subj, heads, args.hop_s, cw)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        cols = {k: (v.astype(str) if v.dtype == object else v) for k, v in res["cols"].items()}
        np.savez_compressed(out + ".tmp.npz", **cols)
        os.replace(out + ".tmp.npz", out)
        if args.replay_dir and res["wire"]:
            rp = os.path.join(args.replay_dir, args.dataset, args.split, f"{subj}.jsonl.gz")
            os.makedirs(os.path.dirname(rp), exist_ok=True)
            with gzip.open(rp + ".tmp", "wt", encoding="utf-8") as f:
                for row in res["wire"]:
                    f.write(json.dumps(row, separators=(",", ":"), allow_nan=False) + "\n")
            os.replace(rp + ".tmp", rp)
        print(f"[eldernet.extract] {args.dataset}/{args.split}/{subj}: {len(res['cols'].get('s', []))} windows",
              file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
