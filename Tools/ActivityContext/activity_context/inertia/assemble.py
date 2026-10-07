"""Assemble cached windows + embeddings + crosswalk targets for one experiment (train/val/test views).

The frozen subject split was applied BEFORE windowing (``meta.split``); here it is re-derived from the
frozen manifests and checked against the cached value, and subject disjointness is asserted on the
windowed arrays. The test split is only ever materialised by ``evaluate_heads`` (inside a TestVault).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence

import numpy as np

from . import cache as C
from .mappings import Crosswalk, load_mappings
from .splits import assert_disjoint_windows, assign_splits, load_splits
from .targets import CLASS_HEADS, class_targets, intensity_targets, transition_targets


@dataclass
class Assembled:
    emb: np.ndarray                  # float32 [N, D]
    meta: object                     # pandas DataFrame
    targets: Dict[str, np.ndarray]   # posture/locomotion/arm_behavior uint16, transition int8 [N,8], movement_intensity f32
    emb_info: Dict[str, Dict]        # per (spec/dataset) embedding cache records
    events: Dict[str, Dict]          # dataset -> {"events": [...], "masked": [...]} (w30t)

    def select(self, mask: np.ndarray) -> "Assembled":
        return Assembled(self.emb[mask], self.meta[mask].reset_index(drop=True),
                         {k: v[mask] for k, v in self.targets.items()}, self.emb_info, self.events)

    def split(self, name: str) -> "Assembled":
        return self.select(self.meta["split"].to_numpy() == name)


def assemble(encoder_id: str, specs: Sequence[str], datasets: Sequence[str], cw: Optional[Crosswalk] = None,
             ood_holdout: bool = False, train_datasets: Optional[Sequence[str]] = None,
             splits_to_load: Sequence[str] = ("train", "val"), cache_root: str = C.CACHE_ROOT) -> Assembled:
    import pandas as pd
    cw = cw or load_mappings()
    embs, metas, trans, infos, events, full = [], [], [], {}, {}, []
    for spec in specs:
        for ds in datasets:
            try:
                X, meta, tr, ev, man = C.load_windows(cache_root, spec, ds)
            except C.CacheError:
                continue
            if not len(meta):
                continue
            E, rec = C.load_embeddings(encoder_id, spec, ds, cache_root)
            full.append(meta[["dataset", "subject", "split"]])        # all splits: leak check on windows
            keep = meta["split"].isin(list(splits_to_load)).to_numpy()
            embs.append(np.asarray(E[keep], np.float32))
            metas.append(meta[keep].assign(spec=spec))
            trans.append(tr[keep])
            infos[f"{spec}/{ds}"] = {k: rec[k] for k in ("encoder_version", "window_index_sha256", "emb_sha256",
                                                         "n_windows", "config_sha256")}
            if spec.endswith("t"):
                events[ds] = ev
    if not metas:
        raise C.CacheError(f"nothing cached for {encoder_id} {list(specs)} {list(datasets)}")
    meta = pd.concat(metas, ignore_index=True)
    emb = np.concatenate(embs)
    tr = np.concatenate(trans)
    _check_splits(pd.concat(full, ignore_index=True), cw)
    tgt: Dict[str, np.ndarray] = {h: class_targets(meta, cw, h, ood_holdout, train_datasets) for h in CLASS_HEADS}
    tgt["movement_intensity"] = intensity_targets(meta, cw, ood_holdout, train_datasets)
    tgt["transition"] = transition_targets(meta, tr, cw, ood_holdout, train_datasets)
    return Assembled(emb, meta, tgt, infos, events)


def _check_splits(meta, cw: Crosswalk) -> None:
    ds = sorted(d for d in meta["dataset"].unique() if cw.role(d) != "ood_only")
    if not ds:
        return
    splits = load_splits(ds)
    m = meta["dataset"].isin(ds).to_numpy()
    expect = assign_splits(meta.loc[m, "subject"].to_numpy(), splits)
    got = meta.loc[m, "split"].to_numpy().astype(str)
    if (expect != got).any():
        raise RuntimeError("cached window split differs from the frozen split manifest (rebuild windows)")
    assert_disjoint_windows(meta.loc[m, "subject"].to_numpy(), got)


def head_rows(a: Assembled, head: str) -> np.ndarray:
    t = a.targets[head]
    if head == "transition":
        return (t >= 0).any(axis=1)
    if head == "movement_intensity":
        return np.isfinite(t)
    return t != 0


def any_target(a: Assembled) -> np.ndarray:
    m = np.zeros(len(a.meta), bool)
    for h in list(CLASS_HEADS) + ["movement_intensity"]:
        m |= head_rows(a, h)
    return m


def activity_keys(meta) -> np.ndarray:
    return (meta["dataset"].astype(str) + "|" + meta["label"].astype(str)).to_numpy()


def is_wrist(meta) -> np.ndarray:
    p = meta["placement"].astype(str)
    return (p.str.startswith("wrist") | p.str.startswith("forearm")).to_numpy()


__all__ = ["Assembled", "assemble", "head_rows", "any_target", "activity_keys", "is_wrist"]


def describe(a: Assembled) -> List[Dict]:
    out = []
    for (ds, sp), g in a.meta.groupby(["dataset", "split"]):
        out.append({"dataset": ds, "split": sp, "windows": int(len(g)), "subjects": int(g["subject"].nunique())})
    return out
