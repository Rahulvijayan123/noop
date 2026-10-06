"""Window targets from the crosswalk, and class-support resolution (INERTIA1.md §5).

* :func:`class_targets` — ``uint16`` bitmask per window and class head, **0 = MASK**. Only pure ``cls``
  windows (one non-null label >= 90%) carry class targets; ``trn`` windows are MASK for class heads. A
  window whose label is withheld (OOD hold-out) or whose dataset is not a training dataset is MASK.
* :func:`intensity_targets` — ``clip(ln MET / ln 12, 0, 1)`` from the label's audited MET, or — for labels whose
  row is ``measured_COSMED`` (GOTOV) — from the window's own measured MET (meta ``met``); NaN = MASK.
* There is no ``unknown`` target anywhere: a missing target is MASK (0 / NaN / -1), never a class.

Support (:func:`resolve_support`): a class is supported iff it has >= 200 TRAIN windows from >= 5 TRAIN
subjects and >= 2 VAL subjects, counting windows whose target is exactly that class, plus — for a
``set_families`` representative — windows whose target set equals the family (``{walking, brisk_walking}``
credits ``walking``). An unsupported family member is then *covered* by its supported representative (the
representative then IS the family). Family members also record their single-label counts
(``single_label_train_windows`` / ``single_label_val_windows``): support lets the representative train on the
family sets, but its operating point, status and test gates only use single-label evidence
(``abstention.SET_RULE``) unless the representative covers every other member.
:meth:`Support.resolve` maps a raw set to the trainable set: supported members kept, covered members
replaced by their cover, and the whole target MASKed if any member is neither supported nor covered.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Mapping, Optional, Sequence

import numpy as np

from . import HEAD_CLASS_ORDERS
from .mappings import Crosswalk, bitmask, met_to_intensity

MIN_TRAIN_WINDOWS = 200
MIN_TRAIN_SUBJECTS = 5
MIN_VAL_SUBJECTS = 2
CLASS_HEADS = ("posture", "locomotion", "arm_behavior")


def _excluded(meta, cw: Crosswalk, ood_holdout: bool, train_datasets: Optional[Sequence[str]]) -> np.ndarray:
    ds = meta["dataset"].to_numpy()
    lab = meta["label"].to_numpy()
    ex = np.zeros(len(meta), bool)
    for d in np.unique(ds):
        m = ds == d
        if cw.role(d) != "train_wrist" or (train_datasets is not None and d not in train_datasets):
            ex[m] = True
        elif ood_holdout:
            held = set(cw.ood_holdout(d))
            if held:
                ex[m] = np.isin(lab[m], list(held))
    return ex


def class_targets(meta, cw: Crosswalk, head: str, ood_holdout: bool = False,
                  train_datasets: Optional[Sequence[str]] = None) -> np.ndarray:
    out = np.zeros(len(meta), np.uint16)
    if not len(meta):
        return out
    ok = (meta["kind"].to_numpy() == "cls") & meta["pure"].to_numpy().astype(bool)
    ok &= ~_excluded(meta, cw, ood_holdout, train_datasets)
    ds, lab = meta["dataset"].to_numpy(), meta["label"].to_numpy()
    cache: Dict[tuple, int] = {}
    for i in np.flatnonzero(ok):
        key = (ds[i], lab[i])
        if key not in cache:
            cache[key] = cw.class_target(ds[i], lab[i], head)
        out[i] = cache[key]
    return out


def intensity_targets(meta, cw: Crosswalk, ood_holdout: bool = False,
                      train_datasets: Optional[Sequence[str]] = None) -> np.ndarray:
    out = np.full(len(meta), np.nan, np.float32)
    if not len(meta):
        return out
    ok = (meta["kind"].to_numpy() == "cls") & meta["pure"].to_numpy().astype(bool)
    ok &= ~_excluded(meta, cw, ood_holdout, train_datasets)
    ds, lab = meta["dataset"].to_numpy(), meta["label"].to_numpy()
    met = (np.asarray(pd_numeric(meta["met"]), np.float64) if "met" in meta.columns
           else np.full(len(meta), np.nan))
    cache: Dict[tuple, tuple] = {}
    for i in np.flatnonzero(ok):
        key = (ds[i], lab[i])
        if key not in cache:
            cache[key] = (cw.intensity_measured(ds[i], lab[i]), cw.intensity_target(ds[i], lab[i]))
        measured, fixed = cache[key]
        if measured:
            out[i] = met_to_intensity(met[i]) if np.isfinite(met[i]) and met[i] > 0 else np.nan
        else:
            out[i] = fixed
    return out


def pd_numeric(col) -> np.ndarray:
    """A meta column as float (None / missing -> NaN)."""
    import pandas as pd
    return pd.to_numeric(col, errors="coerce").to_numpy(np.float64)


def transition_targets(meta, trans: np.ndarray, cw: Crosswalk, ood_holdout: bool = False,
                       train_datasets: Optional[Sequence[str]] = None) -> np.ndarray:
    """int8 [N, 8] (-1 MASK). Windows of excluded datasets/held-out labels are MASK."""
    # Held-out activities have state 'other' and transition rows MASK, so a window that merely touches one
    # is already MASK by construction (unknown boundary / no 'none' row); windows whose modal label is
    # held out, or whose dataset is not trained on, are MASKed here.
    out = np.array(trans, np.int8, copy=True)
    if len(meta):
        out[_excluded(meta, cw, ood_holdout, train_datasets)] = -1
    return out


@dataclass
class Support:
    head: str
    classes: List[str]
    supported: np.ndarray                         # bool [K]
    covers: Dict[str, List[str]]                  # supported class -> [itself, covered unsupported...]
    counts: Dict[str, Dict[str, int]] = field(default_factory=dict)

    def __post_init__(self):
        self._cover_of = {u: c for c, members in self.covers.items() for u in members if u != c}

    def resolve(self, bits: np.ndarray) -> np.ndarray:
        """Raw bitmasks -> trainable bitmasks (see module docstring); vectorised over unique values."""
        bits = np.asarray(bits, np.uint16)
        out = np.zeros_like(bits)
        for v in np.unique(bits):
            if v == 0:
                continue
            new, ok = 0, True
            for k, c in enumerate(self.classes):
                if not (int(v) >> k) & 1:
                    continue
                if self.supported[k]:
                    new |= 1 << k
                elif c in self._cover_of:
                    new |= 1 << self.classes.index(self._cover_of[c])
                else:
                    ok = False
            out[bits == v] = new if ok else 0
        return out

    def to_dict(self) -> Dict:
        return {"supported": [bool(s) for s in self.supported], "covers": self.covers, "counts": self.counts,
                "rule": f">= {MIN_TRAIN_WINDOWS} train windows, >= {MIN_TRAIN_SUBJECTS} train subjects, "
                        f">= {MIN_VAL_SUBJECTS} val subjects (exact-class or family-set windows)"}


def _credit(bits: np.ndarray, head: str, families: Mapping[str, Sequence[str]]) -> np.ndarray:
    """Class index credited by each window (-1 = none): singleton targets and exact family sets."""
    K = len(HEAD_CLASS_ORDERS[head])
    cred = np.full(len(bits), -1, np.int64)
    for k in range(K):
        cred[bits == (1 << k)] = k
    for rep, members in families.items():
        cred[bits == bitmask(members, head)] = HEAD_CLASS_ORDERS[head].index(rep)
    return cred


def resolve_support(head: str, bits_tr: np.ndarray, subj_tr: np.ndarray, bits_va: np.ndarray, subj_va: np.ndarray,
                    families: Mapping[str, Sequence[str]], min_windows: int = MIN_TRAIN_WINDOWS,
                    min_subjects: int = MIN_TRAIN_SUBJECTS, min_val_subjects: int = MIN_VAL_SUBJECTS) -> Support:
    classes = list(HEAD_CLASS_ORDERS[head])
    ctr, cva = _credit(bits_tr, head, families), _credit(bits_va, head, families)
    sup = np.zeros(len(classes), bool)
    counts = {}
    for k, c in enumerate(classes):
        n = int((ctr == k).sum())
        ns = int(len(np.unique(subj_tr[ctr == k])))
        nv = int(len(np.unique(subj_va[cva == k])))
        counts[c] = {"train_windows": n, "train_subjects": ns, "val_windows": int((cva == k).sum()), "val_subjects": nv}
        if any(c in members for members in families.values()):
            # a set-family member: its single-label evidence (exact {c} targets) next to the family-set credit
            one = np.uint16(1 << k)
            counts[c].update({"single_label_train_windows": int((np.asarray(bits_tr) == one).sum()),
                              "single_label_val_windows": int((np.asarray(bits_va) == one).sum())})
        sup[k] = n >= min_windows and ns >= min_subjects and nv >= min_val_subjects
    covers: Dict[str, List[str]] = {}
    for rep, members in families.items():
        if sup[classes.index(rep)]:
            absorbed = [m for m in members if m != rep and not sup[classes.index(m)]]
            if absorbed:
                covers[rep] = [rep] + absorbed
    return Support(head, classes, sup, covers, counts)


def bits_to_matrix(bits: np.ndarray, K: int) -> np.ndarray:
    """uint16 bitmasks -> bool [N, K]."""
    return ((np.asarray(bits, np.int64)[:, None] >> np.arange(K)[None, :]) & 1).astype(bool)


__all__ = ["class_targets", "intensity_targets", "transition_targets", "Support", "resolve_support",
           "bits_to_matrix", "MIN_TRAIN_WINDOWS", "MIN_TRAIN_SUBJECTS", "MIN_VAL_SUBJECTS", "CLASS_HEADS"]
