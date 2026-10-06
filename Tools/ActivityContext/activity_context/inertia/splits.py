"""Frozen subject splits (``nara-split-1``): one manifest per dataset under ``Tools/ActivityContext/splits/``.

Splits are by **subject, before windowing** (spec §13). Each manifest stores ``sha256`` = sha256 of the
canonical JSON of the manifest without the ``sha256`` key; :func:`load_split` refuses a manifest whose
digest does not match, whose split lists overlap, or whose schema is wrong. The manifests were frozen by
Agent C (seed 42; Capture-24 test = the official P102-P151 benchmark; WISDM = Nara HART's seed-42 split
exactly; LOSO folds for the tiny datasets) and are converted here only to the ``nara-split-1`` shape
(subject ids as strings).

Window subjects are namespaced ``<dataset>:<subject>`` everywhere downstream; :func:`assign_splits`
maps namespaced subjects to ``train`` / ``val`` / ``test`` and :func:`assert_disjoint_windows` checks
disjointness on the *windowed* arrays (the leak that matters).
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence

import numpy as np

from . import SPLIT_SCHEMA
from .contract import canonical_json_bytes, sha256_bytes

SPLITS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "splits")
SPLIT_NAMES = ("train", "val", "test")


class SplitError(ValueError):
    """A split manifest is missing, tampered with, or leaks subjects across splits."""


def manifest_sha256(doc: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json_bytes({k: v for k, v in doc.items() if k != "sha256"}))


def make_manifest(dataset: str, train: Sequence, val: Sequence, test: Sequence, *, seed: Any,
                  method: str, note: str = "", loso_folds: Optional[List[Dict[str, List]]] = None,
                  source: str = "") -> Dict[str, Any]:
    doc: Dict[str, Any] = {
        "schema": SPLIT_SCHEMA, "dataset": dataset, "seed": seed, "method": method, "note": note,
        "source": source,
        "train_subjects": sorted(str(s) for s in train), "val_subjects": sorted(str(s) for s in val),
        "test_subjects": sorted(str(s) for s in test),
    }
    if loso_folds:
        doc["loso_folds"] = [{k: sorted(str(s) for s in f[k]) for k in ("train", "val", "test")} for f in loso_folds]
    _check_disjoint(doc)
    doc["sha256"] = manifest_sha256(doc)
    return doc


def _check_disjoint(doc: Mapping[str, Any]) -> None:
    sets = {n: set(doc[f"{n}_subjects"]) for n in SPLIT_NAMES}
    for a, b in (("train", "val"), ("train", "test"), ("val", "test")):
        both = sets[a] & sets[b]
        if both:
            raise SplitError(f"{doc.get('dataset')}: subjects in both {a} and {b}: {sorted(both)[:5]}")


def write_split(doc: Mapping[str, Any], splits_dir: str = SPLITS_DIR) -> str:
    os.makedirs(splits_dir, exist_ok=True)
    path = os.path.join(splits_dir, f"{doc['dataset']}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    return path


def load_split(dataset: str, splits_dir: str = SPLITS_DIR) -> Dict[str, Any]:
    path = os.path.join(splits_dir, f"{dataset}.json")
    if not os.path.isfile(path):
        raise SplitError(f"no frozen split manifest for {dataset!r} at {path}")
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("schema") != SPLIT_SCHEMA:
        raise SplitError(f"{path}: schema must be {SPLIT_SCHEMA!r}")
    if doc.get("sha256") != manifest_sha256(doc):
        raise SplitError(f"{path}: sha256 mismatch (manifest edited after freezing?)")
    _check_disjoint(doc)
    return doc


def load_splits(datasets: Iterable[str], splits_dir: str = SPLITS_DIR) -> Dict[str, Dict[str, Any]]:
    return {d: load_split(d, splits_dir) for d in sorted(set(datasets))}


def combined_sha256(splits: Mapping[str, Mapping[str, Any]]) -> str:
    """One digest over the per-dataset digests (the bundle's ``split_manifest_sha256``)."""
    return sha256_bytes(canonical_json_bytes({d: s["sha256"] for d, s in sorted(splits.items())}))


def subject_split_map(splits: Mapping[str, Mapping[str, Any]]) -> Dict[str, str]:
    """``{"<dataset>:<subject>": "train"|"val"|"test"}``."""
    out: Dict[str, str] = {}
    for ds, doc in splits.items():
        for name in SPLIT_NAMES:
            for s in doc[f"{name}_subjects"]:
                out[f"{ds}:{s}"] = name
    return out


def assign_splits(subjects: np.ndarray, splits: Mapping[str, Mapping[str, Any]],
                  unassigned: str = "error") -> np.ndarray:
    """Split name per window subject (namespaced). Unknown subjects raise (or become '' if allowed)."""
    m = subject_split_map(splits)
    out = np.empty(len(subjects), dtype=object)
    missing = set()
    for i, s in enumerate(subjects):
        v = m.get(str(s))
        if v is None:
            missing.add(str(s))
            v = ""
        out[i] = v
    if missing and unassigned == "error":
        raise SplitError(f"{len(missing)} window subjects are in no frozen split, e.g. {sorted(missing)[:5]}")
    return out.astype(str)


def assert_disjoint_windows(subjects: np.ndarray, split_names: np.ndarray) -> Dict[str, int]:
    """Check on the windowed arrays that no subject has windows in two splits; returns subject counts."""
    subjects = np.asarray(subjects).astype(str)
    split_names = np.asarray(split_names).astype(str)
    per = {}
    for name in SPLIT_NAMES:
        per[name] = set(np.unique(subjects[split_names == name]).tolist())
    for a, b in (("train", "val"), ("train", "test"), ("val", "test")):
        both = per[a] & per[b]
        if both:
            raise SplitError(f"subject leak on windowed arrays: {sorted(both)[:5]} in both {a} and {b}")
    return {k: len(v) for k, v in per.items()}


AGENTC_LARGE_SPLIT = ("Agent C split(): numpy default_rng(42).permutation of the sorted subject ids; first 20% test, "
                      "next 20% val, rest train")
FROZEN_NOTES = {
    "gotov": ("35 participants with a right-wrist GENEActiv file (frozen 2026-10-06 for the NC-SA licence decision); "
              "outdoor walking/cycling exists for 22 of them: 14 train, 6 val, 1 test (GOTOV07)"),
    "wear": "24 subjects sbj_0..23 (frozen 2026-10-06 for the NC-SA licence decision)",
}


def freeze_from_agentc(src_path: str, datasets: Sequence[str], splits_dir: str = SPLITS_DIR) -> List[str]:
    """Convert Agent C's ``split_manifests.json`` into per-dataset ``nara-split-1`` files."""
    with open(src_path, encoding="utf-8") as f:
        src = json.load(f)
    paths = []
    for ds in datasets:
        s = src[ds]
        method = ("official P102-P151 test; P001-P101 seeded 81/20" if ds == "capture24" else
                  "Nara HART split (numpy default_rng(42) shuffle, 15%/15%)" if ds == "wisdm2019_watch" else
                  AGENTC_LARGE_SPLIT if ds in FROZEN_NOTES else "seeded subject permutation (Agent C)")
        doc = make_manifest(ds, s["train_subjects"], s["val_subjects"], s["test_subjects"], seed=s.get("seed"),
                            method=method, note=s.get("note", "") or FROZEN_NOTES.get(ds, ""),
                            loso_folds=s.get("loso_folds"),
                            source=f"Agent C split_manifests.json ({ds})")
        paths.append(write_split(doc, splits_dir))
    return paths


def summary(splits: Mapping[str, Mapping[str, Any]]) -> List[Dict[str, Any]]:
    return [{"dataset": d, "train": len(s["train_subjects"]), "val": len(s["val_subjects"]),
             "test": len(s["test_subjects"]), "loso_folds": len(s.get("loso_folds", [])), "sha256": s["sha256"]}
            for d, s in sorted(splits.items())]


__all__ = ["SplitError", "SPLITS_DIR", "make_manifest", "write_split", "load_split", "load_splits",
           "combined_sha256", "subject_split_map", "assign_splits", "assert_disjoint_windows",
           "freeze_from_agentc", "summary", "manifest_sha256"]
