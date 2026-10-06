"""Dense, label-independent Inertia (STAND-IN, NOT INERTIA-1) windows for the decoder replay (agent R).

P2's saved ``test_predictions`` cover only the label-pure class windows (w30, >= 90 % purity, Capture-24 hop
30 s): replaying those would tell the decoder where the truth is pure and leave it without Inertia evidence
everywhere else. Production computes a window every ``hop_s`` seconds regardless of labels, so this module
regenerates windows the way the serve path does — the bundle's own stand-in encoder (``registry``) and
``HeadBundle.apply`` through P1's ``runtime`` (``build_runtime(..., allow_standin_shadow=True)``), rounded to
6 dp exactly like ``runtime.infer_seconds``:

* Capture-24 (100 Hz g, like WHOOP): ``inertia-prep-1`` itself — P1's ``preprocess.windows_from_run`` on the
  integer-second runs of :func:`replay_data.capture24_participant` (gyro zeros; never read by Inertia).
* WISDM (20 / 50 Hz watch, irregular clock): P2's dataset path — ``datasets.wisdm`` recordings, runs split at
  steps > 0.25 s, linear regrid onto the nominal rate, ``resample_to_20hz``, windows from 1 s after each run
  start on a ``hop_s`` grid — i.e. P2's ``windows.window_recording`` preprocessing without the purity filter.

Windows are expressed as offsets from the matching :class:`replay_export.Recording`'s ``t0``.
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import replay_data as rd
from .replay_export import HeadsWindows, Recording

ROUND = 6


def load_runtime(bundle_dir: str, threads: int = 1):
    """P1's InertiaRuntime for a stand-in bundle (refused by every production path; offline only)."""
    from .runtime import build_runtime
    rt = build_runtime(bundle_dir, allow_standin_shadow=True, threads=threads)
    if not rt.available:
        raise RuntimeError(f"Inertia runtime unavailable: {rt.error}")
    return rt


def bundle_info(rt, hop_s: Optional[int] = None) -> Dict[str, Any]:
    """The motion-heads-1 response minus ``windows`` (what the replay header's ``motion_heads.bundle`` wants)."""
    from . import PREPROCESSING_VERSION
    pre = rt.bundle.preprocessing
    info = rt.info
    return {"encoder_id": info.encoder_id, "encoder_kind": info.wire_kind, "encoder_version": info.encoder_version,
            "checkpoint_sha256": info.checkpoint_sha256, "heads_version": rt.bundle.bundle_id,
            "bundle_sha256": rt.bundle.bundle_sha256, "preprocessing_version": PREPROCESSING_VERSION,
            "evidence_tier_max": rt.evidence_tier_max, "window_s": int(pre["window_s"]),
            "hop_s": int(hop_s if hop_s is not None else pre["hop_s"]), "bundle": rt.bundle.wire_block()}


def _rows_to_heads(rows: Sequence[Dict[str, Any]], s: np.ndarray, e: np.ndarray) -> HeadsWindows:
    """Bundle rows (``HeadBundle.apply``) -> HeadsWindows over the fixed class orders (NaN = unsupported).
    Nonfinite rows are omitted (and counted by the caller)."""
    keep = [i for i, r in enumerate(rows) if not r.get("nonfinite")]
    heads = sorted({h for i in keep for h, v in rows[i].items() if isinstance(v, dict)})
    probs: Dict[str, np.ndarray] = {}
    orders: Dict[str, Tuple[str, ...]] = {}
    from . import HEAD_CLASS_ORDERS
    for h in heads:
        order = tuple(HEAD_CLASS_ORDERS[h])
        orders[h] = order
        p = np.full((len(keep), len(order)), np.nan)
        for j, i in enumerate(keep):
            for c, v in rows[i].get(h, {}).items():
                p[j, order.index(c)] = round(float(v), ROUND)
        probs[h] = p
    mi = np.array([round(float(rows[i].get("movement_intensity", np.nan)), ROUND) for i in keep])
    ood = np.array([round(float(rows[i].get("ood_score", np.nan)), ROUND) for i in keep])
    is_ood = np.array([bool(rows[i].get("is_ood", False)) for i in keep])
    return HeadsWindows(s=np.asarray(s)[keep].astype(np.int64), e=np.asarray(e)[keep].astype(np.int64),
                        probs=probs, class_order=orders, movement_intensity=mi, ood_score=ood, is_ood=is_ood)


def _embed_apply(rt, X: np.ndarray) -> List[Dict[str, Any]]:
    from .runtime import embed_batched
    if X.shape[0] == 0:
        return []
    emb = embed_batched(rt.encoder, X.astype(np.float32), rt.max_batch)
    return rt.bundle.apply(emb)


# ---------------------------------------------------------------------------
# Capture-24: inertia-prep-1 on the integer-second 100 Hz runs
# ---------------------------------------------------------------------------

def capture24_heads(rec: Recording, rt, hop_s: int, c24_dir: str = rd.CAPTURE24_DIR) -> Tuple[HeadsWindows, Dict]:
    import pyarrow.parquet as pq
    from ..preprocess import Run
    from .preprocess import windows_from_run, stack_windows

    pid = rec.subject
    window_s = int(rt.bundle.preprocessing["window_s"])
    tbl = pq.read_table(os.path.join(c24_dir, f"pid={pid}", "data.parquet"), columns=["timestamp_ms", "x", "y", "z"])
    ts = tbl.column("timestamp_ms").to_numpy().astype(np.int64)
    xyz = np.stack([tbl.column(c).to_numpy().astype(np.float64) for c in ("x", "y", "z")], axis=1)
    del tbl
    sec = ts // 1000
    uniq, first, counts = np.unique(sec, return_index=True, return_counts=True)
    pos = {int(u): int(f) for u, f, c in zip(uniq, first, counts) if c == 100}
    abs_secs = rec.t0 + rec.sec
    brk = np.flatnonzero(np.diff(abs_secs) != 1) + 1
    S: List[int] = []
    E: List[int] = []
    rows: List[Dict[str, Any]] = []
    n_runs = 0
    for idx in np.split(np.arange(rec.n), brk):
        if len(idx) == 0:
            continue
        s0, s1 = int(abs_secs[idx[0]]), int(abs_secs[idx[-1]]) + 1
        if s1 - s0 < window_s + 2:
            continue
        starts = np.array([pos[int(s)] for s in abs_secs[idx]])
        acc = xyz[(starts[:, None] + np.arange(100)[None, :]).reshape(-1)]
        samples = np.concatenate([acc, np.zeros_like(acc)], axis=1)
        run = Run(start_ts=s0, samples=samples, end_ts=s1)
        wins = windows_from_run(run, s0, s1, window_s, hop_s)
        if not wins:
            continue
        n_runs += 1
        rows += _embed_apply(rt, stack_windows(wins))
        S += [w.s - rec.t0 for w in wins]
        E += [w.e - rec.t0 for w in wins]
    hw = _rows_to_heads(rows, np.asarray(S, np.int64), np.asarray(E, np.int64))
    return hw, {"windows": len(rows), "nonfinite": len(rows) - len(hw), "runs": n_runs}


# ---------------------------------------------------------------------------
# WISDM: P2's dataset path (irregular watch clock -> regrid -> 20 Hz), dense grid
# ---------------------------------------------------------------------------

def wisdm_heads(subject: int, recs: Sequence[Recording], rt, hop_s: int) -> Tuple[Dict[str, HeadsWindows], Dict]:
    from .datasets import wisdm as dw
    from . import preprocess as ipre
    from .windows import _regrid, EDGE_S, RATE

    window_s = int(rt.bundle.preprocessing["window_s"])
    by_index = {int(r.meta["block_index"]): r for r in recs if r.subject == str(subject)}
    out: Dict[str, HeadsWindows] = {}
    stats = {"recordings": 0, "windows": 0, "nonfinite": 0, "unmatched_blocks": 0, "t0_mismatch": 0}
    t0_ns = {int(r.meta["block_index"]): None for r in by_index.values()}
    # the block's first accel timestamp is stored in the WISDM cache; recompute from the raw file
    acts, ts_ns, _xyz = rd.parse_wisdm_raw(os.path.join(rd.WISDM_DIR, "raw", "watch", "accel",
                                                        f"data_{subject}_accel_watch.txt"))
    for bi, (a, _b) in enumerate(rd.split_recordings(acts, ts_ns)):
        if bi in t0_ns:
            t0_ns[bi] = int(ts_ns[a])
    for prec in dw.iter_recordings(subjects=[str(subject)]):
        bi = int(prec.session.rsplit(":b", 1)[1])
        rec = by_index.get(bi)
        if rec is None:
            stats["unmatched_blocks"] += 1
            continue
        base = t0_ns[bi] / 1e9
        if abs(float(prec.t[0]) - base) > 1e-6:
            stats["t0_mismatch"] += 1
            continue
        S: List[float] = []
        Xs: List[np.ndarray] = []
        for sl in ipre.segment_on_gaps(prec.t, max_gap_s=prec.split_step_s):
            t, x = prec.t[sl], prec.xyz_g[sl]
            if len(t) < 2 or (t[-1] - t[0]) < window_s + 2 * EDGE_S:
                continue
            if not prec.uniform:
                t, x = _regrid(t, x, prec.source_hz)
            try:
                x20 = ipre.resample_to_20hz(x, prec.source_hz)
            except ipre.PreprocessError:
                continue
            run_end = t[-1] + 1.0 / prec.source_hz
            starts = np.arange(t[0] + EDGE_S, run_end - EDGE_S - window_s + 1e-9, hop_s)
            T = window_s * RATE
            i0 = np.round((starts - t[0]) * RATE).astype(np.int64)
            ok = i0 + T <= len(x20)
            for s, i in zip(starts[ok], i0[ok]):
                Xs.append(np.ascontiguousarray(x20[i:i + T].T))
                S.append(float(s))
        if not Xs:
            continue
        rows = _embed_apply(rt, np.stack(Xs))
        s_rel = np.round(np.asarray(S) - base).astype(np.int64)      # starts are base + 1 + k*hop
        hw = _rows_to_heads(rows, s_rel, s_rel + window_s)
        out[rec.recording_id] = hw
        stats["recordings"] += 1
        stats["windows"] += len(rows)
        stats["nonfinite"] += len(rows) - len(hw)
    return out, stats


# ---------------------------------------------------------------------------
# Cache I/O
# ---------------------------------------------------------------------------

def save_heads(heads: Dict[str, HeadsWindows], path: str, meta: Optional[Dict[str, Any]] = None) -> None:
    arrays: Dict[str, Any] = {}
    index = []
    for i, (rid, h) in enumerate(sorted(heads.items())):
        p = f"h{i}_"
        arrays[p + "s"] = h.s
        arrays[p + "e"] = h.e
        for k, v in h.probs.items():
            arrays[p + "p_" + k] = v
        arrays[p + "mi"] = h.movement_intensity if h.movement_intensity is not None else np.zeros(0)
        arrays[p + "ood"] = h.ood_score if h.ood_score is not None else np.zeros(0)
        arrays[p + "isood"] = h.is_ood if h.is_ood is not None else np.zeros(0, bool)
        index.append({"recording_id": rid, "heads": sorted(h.probs), "class_order": {k: list(v) for k, v in h.class_order.items()}})
    arrays["index_json"] = np.asarray(json.dumps({"index": index, "meta": meta or {}}))
    tmp = path + ".tmp.npz"
    np.savez_compressed(tmp, **arrays)
    os.replace(tmp, path)


def load_heads(path: str) -> Tuple[Dict[str, HeadsWindows], Dict[str, Any]]:
    z = np.load(path, allow_pickle=False)
    doc = json.loads(str(z["index_json"]))
    out: Dict[str, HeadsWindows] = {}
    for i, m in enumerate(doc["index"]):
        p = f"h{i}_"
        mi = z[p + "mi"]
        out[m["recording_id"]] = HeadsWindows(
            s=z[p + "s"], e=z[p + "e"], probs={k: z[p + "p_" + k] for k in m["heads"]},
            class_order={k: tuple(v) for k, v in m["class_order"].items()},
            movement_intensity=mi if len(mi) else None, ood_score=z[p + "ood"], is_ood=z[p + "isood"])
    return out, doc.get("meta", {})


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse
    import time
    from concurrent.futures import ProcessPoolExecutor
    from . import replay_export as rx

    ap = argparse.ArgumentParser(description="dense stand-in Inertia windows for the replay (agent R)")
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--dataset", choices=("wisdm", "capture24"), required=True)
    ap.add_argument("--split", choices=("test", "val"), required=True)
    ap.add_argument("--hop", type=int, default=None, help="default: the bundle's hop_s")
    ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args(argv)
    t = time.time()
    recs = rx.load_recordings(os.path.join(rd.REPLAY_DIR, f"recordings_{a.dataset}_{a.split}.npz"))
    rt = load_runtime(a.bundle)
    hop = int(a.hop if a.hop is not None else rt.bundle.preprocessing["hop_s"])
    heads: Dict[str, HeadsWindows] = {}
    stats: Dict[str, Any] = {}
    with ProcessPoolExecutor(max_workers=a.jobs) as ex:
        if a.dataset == "wisdm":
            subs = sorted({int(r.subject) for r in recs})
            futs = {s: ex.submit(_wisdm_job, a.bundle, s, [r for r in recs if r.subject == str(s)], hop) for s in subs}
        else:
            futs = {r.recording_id: ex.submit(_c24_job, a.bundle, r, hop) for r in recs}
        for k, f in futs.items():
            h, st = f.result()
            if isinstance(h, dict):
                heads.update(h)
            else:
                heads[k] = h
            stats[str(k)] = st
    meta = {"bundle": bundle_info(rt, hop), "dataset": a.dataset, "split": a.split, "hop_s": hop,
            "stats": stats, "banner": rd.STANDIN_BANNER, "seconds": round(time.time() - t, 1)}
    save_heads(heads, a.out, meta)
    print(json.dumps({"out": a.out, "recordings": len(heads), "windows": int(sum(len(h) for h in heads.values())),
                      "seconds": meta["seconds"]}))
    return 0


def _wisdm_job(bundle_dir: str, subject: int, recs: Sequence[Recording], hop: int):
    return wisdm_heads(subject, recs, load_runtime(bundle_dir), hop)


def _c24_job(bundle_dir: str, rec: Recording, hop: int):
    return capture24_heads(rec, load_runtime(bundle_dir), hop)


if __name__ == "__main__":
    import sys
    sys.exit(main())
