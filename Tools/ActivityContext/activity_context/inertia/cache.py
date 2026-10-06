"""On-disk caches for windows and embeddings (outside git; default ``research/inertia-cache``).

Layout::

    <root>/windows/<spec>/<dataset>/X.npy           float32 [N, 3, T] (20 Hz, g)
                                    meta.parquet    one row per window (uid, subject, split, t0, label, ...)
                                    trans.npy       int8 [N, 8] transition targets (-1 MASK)
                                    events.json     timing ground truth + masked spans (w30t only)
                                    manifest.json   counts, versions, window_index_sha256
    <root>/emb/<encoder slug>/<spec>/<dataset>.npy  float32 [N, D]
                                    <dataset>.json  encoder id/version/config sha, window_index_sha256, emb sha256

``window_index_sha256`` = sha256 over the newline-joined window uids (stored order) + spec + versions; an
embedding cache is only reused when its recorded window index digest and encoder version match.
Windowing/embedding run in worker processes (one recording unit per task); results are deterministic and
independent of the worker count (each window is processed alone; batches never mix runs in a way that
changes values — P1's encoders are batch-invariant, checked in tests).
"""

from __future__ import annotations

import json
import os
import shutil
import time
from concurrent.futures import ProcessPoolExecutor
from typing import Any, Dict, List, Optional, Sequence

import numpy as np

from . import datasets as D
from .contract import canonical_json_bytes, sha256_bytes
from .mappings import load_mappings
from .splits import load_splits, subject_split_map
from .windows import SPECS, WINDOWS_VERSION, window_recording

CACHE_ROOT = os.environ.get("INERTIA_CACHE_DIR", "/Volumes/External SSD/Nara Whoop App V2/research/inertia-cache")


class CacheError(RuntimeError):
    pass


def windows_dir(root: str, spec: str, dataset: str) -> str:
    return os.path.join(root, "windows", spec, dataset)


def _work(args) -> Dict[str, Any]:
    dataset, unit, spec_names, split_map, shard_dir, data_root = args
    cw = load_mappings()
    specs = [SPECS[s] for s in spec_names]
    counts = {s: 0 for s in spec_names}
    infos = []
    for rec in D.iter_recordings(dataset, root=data_root, subjects=[unit]):
        split = split_map.get(rec.subject, "ood" if cw.role(dataset) == "ood_only" else "")
        if not split:
            raise CacheError(f"{rec.subject} is in no frozen split")
        out = window_recording(rec, cw, specs, split)
        safe = rec.session.replace(":", "_").replace("/", "_")
        for s, v in out.items():
            if not v["meta"]:
                continue
            np.save(os.path.join(shard_dir, s, f"{safe}.X.npy"), v["X"])
            np.save(os.path.join(shard_dir, s, f"{safe}.trans.npy"), v["trans"])
            with open(os.path.join(shard_dir, s, f"{safe}.meta.json"), "w") as f:
                json.dump({"meta": v["meta"], "events": v["events"], "masked": v["masked"]}, f)
            counts[s] += len(v["meta"])
        infos.append({"session": rec.session, "subject": rec.subject, "split": split, "n_samples": int(len(rec.t)),
                      "meta": rec.meta})
    return {"unit": unit, "counts": counts, "recordings": infos}


def build_windows(dataset: str, spec_names: Sequence[str] = ("w30", "w30t", "w10"), root: str = CACHE_ROOT,
                  workers: int = 8, data_root: Optional[str] = None, units: Optional[Sequence[str]] = None,
                  force: bool = False) -> Dict[str, Any]:
    cw = load_mappings()
    splits = load_splits([dataset]) if cw.role(dataset) != "ood_only" else {}
    split_map = subject_split_map(splits)
    todo = [s for s in spec_names if force or not os.path.isfile(os.path.join(windows_dir(root, s, dataset), "manifest.json"))]
    if not todo:
        return {s: read_manifest(root, s, dataset) for s in spec_names}
    shard_dir = os.path.join(root, "shards", dataset)
    shutil.rmtree(shard_dir, ignore_errors=True)
    for s in todo:
        os.makedirs(os.path.join(shard_dir, s), exist_ok=True)
    units = list(units or D.list_units(dataset, data_root))
    t0 = time.time()
    tasks = [(dataset, u, list(todo), split_map, shard_dir, data_root) for u in units]
    if workers <= 1 or dataset == "hhar_watch":          # HHAR: one 327 MB CSV, load it once
        results = [_work(t) for t in tasks]
    else:
        with ProcessPoolExecutor(max_workers=workers) as ex:
            results = list(ex.map(_work, tasks))
    recs = [r for res in results for r in res["recordings"]]
    out = {}
    for s in todo:
        out[s] = _merge(root, s, dataset, os.path.join(shard_dir, s), recs, cw.sha256,
                        splits_sha={d: v["sha256"] for d, v in splits.items()}, seconds=time.time() - t0)
    shutil.rmtree(shard_dir, ignore_errors=True)
    return out


def _merge(root: str, spec: str, dataset: str, shard_dir: str, recs: List[Dict], mappings_sha: str,
           splits_sha: Dict[str, str], seconds: float) -> Dict[str, Any]:
    import pandas as pd
    names = sorted(f[:-len(".meta.json")] for f in os.listdir(shard_dir) if f.endswith(".meta.json"))
    metas, events, masked, sizes = [], [], [], []
    for n in names:
        with open(os.path.join(shard_dir, f"{n}.meta.json")) as f:
            d = json.load(f)
        metas += d["meta"]
        events += d["events"]
        masked += d["masked"]
        sizes.append(len(d["meta"]))
    out_dir = windows_dir(root, spec, dataset)
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir)
    N, T = sum(sizes), SPECS[spec].window_s * 20
    X = np.lib.format.open_memmap(os.path.join(out_dir, "X.npy"), mode="w+", dtype=np.float32, shape=(N, 3, T))
    trans = np.zeros((N, 8), np.int8)
    k = 0
    for n, sz in zip(names, sizes):
        X[k:k + sz] = np.load(os.path.join(shard_dir, f"{n}.X.npy"))
        trans[k:k + sz] = np.load(os.path.join(shard_dir, f"{n}.trans.npy"))
        k += sz
    X.flush()
    del X
    np.save(os.path.join(out_dir, "trans.npy"), trans)
    meta = pd.DataFrame(metas)
    meta.to_parquet(os.path.join(out_dir, "meta.parquet"), index=False)
    with open(os.path.join(out_dir, "events.json"), "w") as f:
        json.dump({"events": events, "masked": masked}, f)
    uids = meta["uid"].tolist() if N else []
    if len(set(uids)) != len(uids):
        raise CacheError(f"{dataset}/{spec}: duplicate window uids")
    man = {"dataset": dataset, "spec": spec, "window_s": SPECS[spec].window_s, "kind": SPECS[spec].kind,
           "hop_s": SPECS[spec].hop_s(dataset), "n_windows": int(N), "windows_version": WINDOWS_VERSION,
           "loader_version": D.loader(dataset).LOADER_VERSION, "label_mappings_sha256": mappings_sha,
           "split_sha256": splits_sha, "window_index_sha256": window_index_sha256(uids, spec),
           "n_by_split": meta["split"].value_counts().to_dict() if N else {},
           "n_subjects": int(meta["subject"].nunique()) if N else 0,
           "recordings": recs, "build_seconds": round(seconds, 1)}
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1, default=str)
    return man


def window_index_sha256(uids: Sequence[str], spec: str) -> str:
    return sha256_bytes(("\n".join(uids) + f"\n#{spec}#{WINDOWS_VERSION}").encode("utf-8"))


def read_manifest(root: str, spec: str, dataset: str) -> Dict[str, Any]:
    p = os.path.join(windows_dir(root, spec, dataset), "manifest.json")
    if not os.path.isfile(p):
        raise CacheError(f"no window cache for {dataset}/{spec} (run: pipeline_cli windows)")
    with open(p) as f:
        return json.load(f)


def load_windows(root: str, spec: str, dataset: str, mmap: bool = True, with_x: bool = False):
    """(X or None, meta, trans, events, manifest). Training/evaluation only need meta + embeddings, so the
    raw-window tensor is opened only on request (``with_x``)."""
    import pandas as pd
    d = windows_dir(root, spec, dataset)
    man = read_manifest(root, spec, dataset)
    X = np.load(os.path.join(d, "X.npy"), mmap_mode="r" if mmap else None) if with_x else None
    meta = pd.read_parquet(os.path.join(d, "meta.parquet"))
    trans = np.load(os.path.join(d, "trans.npy"))
    with open(os.path.join(d, "events.json")) as f:
        ev = json.load(f)
    return X, meta, trans, ev, man


# ---------------------------------------------------------------------------
# Embeddings
# ---------------------------------------------------------------------------

def encoder_slug(encoder_id: str) -> str:
    return encoder_id.replace("standin:", "standin-").replace("/", "__").replace("@", "_at_")


def _embed_chunk(args) -> np.ndarray:
    spec, window_s, x_path, a, b, kw = args
    from .registry import build_encoder
    enc = build_encoder(spec, window_s=window_s, **kw)
    X = np.load(x_path, mmap_mode="r")
    return enc.embed(np.array(X[a:b], dtype=np.float32))          # writable copy of the memmap slice


def embed_dataset(encoder_spec: str, spec: str, dataset: str, root: str = CACHE_ROOT, workers: int = 8,
                  chunk: int = 4096, encoder_kw: Optional[Dict[str, Any]] = None, force: bool = False) -> Dict[str, Any]:
    from .registry import build_encoder
    kw = dict(encoder_kw or {})
    man = read_manifest(root, spec, dataset)
    window_s = SPECS[spec].window_s
    enc = build_encoder(encoder_spec, window_s=window_s, **kw)          # typed InertiaUnavailable if blocked
    info = enc.info
    out_dir = os.path.join(root, "emb", encoder_slug(info.encoder_id), spec)
    os.makedirs(out_dir, exist_ok=True)
    npy, js = os.path.join(out_dir, f"{dataset}.npy"), os.path.join(out_dir, f"{dataset}.json")
    if not force and os.path.isfile(js):
        with open(js) as f:
            old = json.load(f)
        if old.get("window_index_sha256") == man["window_index_sha256"] and old.get("encoder_version") == info.encoder_version:
            return old
    N = man["n_windows"]
    x_path = os.path.join(windows_dir(root, spec, dataset), "X.npy")
    t0 = time.time()
    tasks = [(encoder_spec, window_s, x_path, a, min(a + chunk, N), kw) for a in range(0, N, chunk)]
    if workers <= 1 or len(tasks) <= 1:
        parts = [_embed_chunk(t) for t in tasks]
    else:
        with ProcessPoolExecutor(max_workers=workers) as ex:
            parts = list(ex.map(_embed_chunk, tasks))
    E = np.concatenate(parts).astype(np.float32) if parts else np.zeros((0, info.embedding_dim), np.float32)
    if E.shape != (N, info.embedding_dim) or not np.isfinite(E).all():
        raise CacheError(f"{encoder_spec}/{spec}/{dataset}: bad embeddings {E.shape}")
    np.save(npy, E)
    rec = {"encoder_id": info.encoder_id, "encoder_version": info.encoder_version, "kind": info.kind,
           "config_sha256": info.config_sha256, "checkpoint_sha256": info.checkpoint_sha256,
           "embedding_dim": info.embedding_dim, "dataset": dataset, "spec": spec,
           "window_index_sha256": man["window_index_sha256"], "n_windows": N,
           "emb_sha256": sha256_bytes(np.ascontiguousarray(E).tobytes()), "seconds": round(time.time() - t0, 1),
           "info": info.to_dict()}
    with open(js, "w") as f:
        json.dump(rec, f, indent=1)
    return rec


def load_embeddings(encoder_id: str, spec: str, dataset: str, root: str = CACHE_ROOT):
    d = os.path.join(root, "emb", encoder_slug(encoder_id), spec)
    with open(os.path.join(d, f"{dataset}.json")) as f:
        rec = json.load(f)
    man = read_manifest(root, spec, dataset)
    if rec["window_index_sha256"] != man["window_index_sha256"]:
        raise CacheError(f"embedding cache for {encoder_id}/{spec}/{dataset} is stale (window index changed)")
    return np.load(os.path.join(d, f"{dataset}.npy")), rec


__all__ = ["CACHE_ROOT", "CacheError", "build_windows", "load_windows", "read_manifest", "embed_dataset",
           "load_embeddings", "encoder_slug", "window_index_sha256", "windows_dir"]
