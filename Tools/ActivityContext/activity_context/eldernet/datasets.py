"""Raw-rate public-dataset accessor for ElderNet validation (offline only; ELDERNET.md §7).

The Inertia loaders (``activity_context.inertia.datasets``) already yield source-rate streams in g with a label
per sample; this module only windows them for ElderNet, never through the Inertia 20 Hz path:

* runs split wherever a step exceeds ``Recording.split_step_s`` or is <= 0, and at loader-repaired samples
  (PAMAP2 ``filled``) — no imputation reaches ElderNet;
* each run -> 30 Hz by the time-correct nearest-neighbour rule (:func:`preprocess.nearest_timestamp_index`,
  equal to upstream/actipy on uniform 100 Hz), windows of 300 samples every ``hop_s`` from the run start;
* per-window truth from the audited crosswalk (``label_mappings.json``, locomotion head, only rows with
  ``used_for_training``): GAIT = every member in {walking, brisk_walking, stairs}; NON_GAIT = every member in
  {stationary, cycling, vehicle_motion}; RUNNING = {running}; anything else (other, mixed sets, null) MASK.
  A window takes a truth category only if >= 90 % of its 300 samples carry it (inertia PURITY), else MASK.

:func:`score_recording` runs the served window-local detector (:func:`gait.score_windows`) on the windows.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterator, List, Optional, Sequence

import numpy as np

from . import QUALITY_HEADS, RATE_HZ, WINDOW_S, WINDOW_SAMPLES
from .gait import score_windows
from .preprocess import nearest_timestamp_index

GAIT, NON_GAIT, RUNNING, MASK = 1, 0, 2, -1
PURITY = 0.9
LOCOMOTION = ("stationary", "walking", "brisk_walking", "running", "stairs", "cycling", "vehicle_motion", "other")
_BIT = {c: 1 << i for i, c in enumerate(LOCOMOTION)}
GAIT_BITS = _BIT["walking"] | _BIT["brisk_walking"] | _BIT["stairs"]
NON_GAIT_BITS = _BIT["stationary"] | _BIT["cycling"] | _BIT["vehicle_motion"]


def truth_of_mask(mask: int) -> int:
    if mask == 0:
        return MASK
    if mask & ~GAIT_BITS == 0:
        return GAIT
    if mask & ~NON_GAIT_BITS == 0:
        return NON_GAIT
    if mask == _BIT["running"]:
        return RUNNING
    return MASK


def truth_table(cw, dataset: str, label_names: Sequence[str]) -> np.ndarray:
    """Truth category per label code (int8), from the crosswalk's locomotion targets."""
    out = []
    for name in label_names:
        out.append(truth_of_mask(cw.class_target(dataset, name, "locomotion")) if cw.has_label(dataset, name)
                   else MASK)
    return np.array(out, np.int8)


def split_runs(t: np.ndarray, max_step_s: float, bad: Optional[np.ndarray] = None) -> List[slice]:
    """Maximal runs with 0 < step <= max_step_s, excluding ``bad`` samples (they end a run)."""
    t = np.asarray(t, np.float64)
    n = t.size
    if n == 0:
        return []
    cut = np.zeros(n, bool)
    cut[1:] = (np.diff(t) > max_step_s) | (np.diff(t) <= 0)
    keep = np.ones(n, bool) if bad is None else ~np.asarray(bad, bool)
    prev_keep = np.concatenate([[False], keep[:-1]])
    starts = np.flatnonzero(keep & (cut | ~prev_keep))
    nxt = np.concatenate([starts[1:], [n]])
    out = []
    for a0, b0 in zip(starts, nxt):
        stop = a0 + int(np.argmin(keep[a0:b0])) if not keep[a0:b0].all() else b0
        out.append(slice(int(a0), int(stop)))
    return [s for s in out if s.stop - s.start > 1]


@dataclass
class WindowSet:
    """Windows of one recording (data float64 [B, 300, 3]) with provenance and truth."""
    data: np.ndarray
    s: np.ndarray
    label: List[str]
    purity: np.ndarray
    truth: np.ndarray
    label_purity: np.ndarray = None
    meta: Dict = field(default_factory=dict)


def recording_windows(rec, truth_codes: np.ndarray, hop_s: float = 5.0) -> WindowSet:
    """All 10 s windows of a dataset :class:`~activity_context.inertia.datasets.Recording` (module docstring)."""
    hop = int(round(hop_s * RATE_HZ))
    datas, ss, labs, purs, truths, lpurs = [], [], [], [], [], []
    for sl in split_runs(rec.t, rec.split_step_s, rec.filled):
        t, x, codes = rec.t[sl], rec.xyz_g[sl], rec.labels[sl]
        if t[-1] - t[0] < WINDOW_S or not np.isfinite(x).all():
            continue
        idx = nearest_timestamp_index(t)
        x30, c30 = x[idx], codes[idx]
        cat30 = truth_codes[c30]
        for k in range(0, len(idx) - WINDOW_SAMPLES + 1, hop):
            cat = cat30[k:k + WINDOW_SAMPLES]
            vals, cnt = np.unique(cat, return_counts=True)
            j = int(np.argmax(cnt))
            pur = float(cnt[j]) / WINDOW_SAMPLES
            lab_vals, lab_cnt = np.unique(c30[k:k + WINDOW_SAMPLES], return_counts=True)
            datas.append(x30[k:k + WINDOW_SAMPLES])
            ss.append(float(t[0] + k / RATE_HZ))
            labs.append(rec.label_names[int(lab_vals[int(np.argmax(lab_cnt))])])
            lpurs.append(float(lab_cnt.max()) / WINDOW_SAMPLES)
            purs.append(pur)
            truths.append(int(vals[j]) if pur >= PURITY else MASK)
    data = np.stack(datas) if datas else np.zeros((0, WINDOW_SAMPLES, 3))
    return WindowSet(data=data, s=np.array(ss, np.float64), label=labs, purity=np.array(purs),
                     truth=np.array(truths, np.int8), label_purity=np.array(lpurs),
                     meta={"dataset": rec.dataset, "subject": rec.subject, "session": rec.session,
                           "placement": rec.placement, "source_hz": float(rec.source_hz)})


COLUMNS = ("s", "e", "purity", "truth", "prefiltered", "logit_diff", "gait_prob", "is_gait", "finite") + \
    tuple(v[0] for v in QUALITY_HEADS.values())


def score_recording(heads, ws: WindowSet, quality: bool = True) -> Dict[str, np.ndarray]:
    """Served detector (T = 1, threshold 0.5) on a WindowSet -> column arrays (metrics NaN off gait)."""
    sc = score_windows(heads, ws.data, quality=quality)
    out = {"s": ws.s, "e": ws.s + WINDOW_S, "purity": ws.purity, "label_purity": ws.label_purity,
           "truth": ws.truth, "prefiltered": sc.prefiltered,
           "logit_diff": sc.logit_diff, "gait_prob": sc.gait_prob, "is_gait": sc.is_gait, "finite": sc.finite}
    for name, (key, _, _, _) in QUALITY_HEADS.items():
        out[key] = sc.metrics[name]
    return out


def iter_split_recordings(dataset: str, subjects: Sequence[str]) -> Iterator:
    from ..inertia.datasets import iter_recordings
    for subj in subjects:
        yield from iter_recordings(dataset, subjects=[subj])


__all__ = ["GAIT", "NON_GAIT", "RUNNING", "MASK", "PURITY", "truth_of_mask", "truth_table", "split_runs",
           "WindowSet", "recording_windows", "COLUMNS", "score_recording", "iter_split_recordings"]
