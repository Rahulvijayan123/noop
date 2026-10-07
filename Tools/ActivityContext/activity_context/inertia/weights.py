"""Class weights and row balancing — computed from TRAIN rows only.

* :func:`class_weights` — inverse frequency over supported classes (a set-target row contributes ``1/|S|``
  to each member), clipped to [0.2, 5] and renormalised to mean 1 over supported classes; unsupported
  classes get 0. :func:`event_pos_weights` does the same per event for the multi-label head
  (``n_neg / n_pos`` clipped to [1, 50]).
* :func:`balance_rows` — sqrt-dataset / sqrt-subject balancing: inside a dataset each subject's total
  weight is proportional to sqrt(its rows), each dataset's total to sqrt(its rows); mean 1 over rows.
  Capture-24's ~158k train windows therefore do not drown WISDM/PAMAP2, and a subject with 10x the
  windows gets ~3x (not 10x) the say.

Callers pass TRAIN arrays explicitly; :func:`assert_train_only` guards the split label.
"""

from __future__ import annotations

from typing import Dict, Tuple

import numpy as np

CLIP = (0.2, 5.0)
POS_WEIGHT_CLIP = (1.0, 50.0)


class LeakError(RuntimeError):
    pass


def assert_train_only(split_names: np.ndarray) -> None:
    s = set(np.unique(np.asarray(split_names).astype(str)).tolist())
    if s - {"train"}:
        raise LeakError(f"class weights / balancing must use TRAIN rows only, got splits {sorted(s)}")


def class_weights(bits_train: np.ndarray, supported: np.ndarray, clip: Tuple[float, float] = CLIP) -> np.ndarray:
    K = len(supported)
    m = ((np.asarray(bits_train, np.int64)[:, None] >> np.arange(K)[None, :]) & 1).astype(np.float64)
    m = m[m.sum(1) > 0]
    frac = m / m.sum(1, keepdims=True)
    n = frac.sum(0)
    w = np.zeros(K)
    sup = np.asarray(supported, bool) & (n > 0)
    if sup.any():
        w[sup] = n[sup].sum() / (sup.sum() * n[sup])
        w[sup] = np.clip(w[sup], *clip)
        w[sup] *= sup.sum() / w[sup].sum()
    return w


def event_pos_weights(targets_train: np.ndarray, supported: np.ndarray,
                      clip: Tuple[float, float] = POS_WEIGHT_CLIP) -> np.ndarray:
    t = np.asarray(targets_train)
    pos = (t == 1).sum(0).astype(np.float64)
    neg = (t == 0).sum(0).astype(np.float64)
    w = np.where(pos > 0, neg / np.maximum(pos, 1), 1.0)
    w = np.clip(w, *clip)
    return np.where(np.asarray(supported, bool), w, 1.0)


def balance_rows(datasets: np.ndarray, subjects: np.ndarray) -> np.ndarray:
    datasets = np.asarray(datasets).astype(str)
    subjects = np.asarray(subjects).astype(str)
    w = np.zeros(len(subjects), np.float64)
    if not len(w):
        return w
    for d in np.unique(datasets):
        md = datasets == d
        subs, inv, cnt = np.unique(subjects[md], return_inverse=True, return_counts=True)
        a = 1.0 / np.sqrt(cnt)                       # per-row weight inside the dataset
        total = np.sqrt(cnt).sum()                   # = sum over rows of a
        w[md] = a[inv] * np.sqrt(md.sum()) / total
    return w / w.mean()


def summarize(bits_train: np.ndarray, supported: np.ndarray, classes) -> Dict[str, float]:
    w = class_weights(bits_train, supported)
    return {c: round(float(v), 6) for c, v in zip(classes, w)}


__all__ = ["class_weights", "event_pos_weights", "balance_rows", "assert_train_only", "LeakError", "summarize"]
