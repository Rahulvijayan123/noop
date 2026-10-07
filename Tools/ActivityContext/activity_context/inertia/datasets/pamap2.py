"""PAMAP2 (UCI 231; CC BY 4.0): hand IMU ``acc16`` (+-16 g, m/s^2), 100 Hz, Protocol + Optional sessions.

Columns used: 0 timestamp (s), 1 activityID, 4-6 hand acc16 x/y/z. Column 2 (heart rate) and every other
physiology/temperature column are never parsed. The hand IMU is on the dominant wrist: right for 101-107
and 109, left for 108 (subjectInformation). ``0`` = transient (explicit null label).

Loader repair ``pamap2-fill-50ms`` (dataset-specific, never applied to WHOOP data): NaN dropouts of
<= 5 consecutive samples (<= 50 ms, less than one 20 Hz output sample) whose neighbours carry the same
activity are linearly interpolated and flagged in ``filled``; longer dropouts are removed, which splits
the run (no interpolation across them).
"""

from __future__ import annotations

import os
from typing import Iterator, List, Optional, Sequence

import numpy as np

from ..paths import under
from . import HAR_ROOT, DatasetError, Recording, ms2_to_g, resolve_root

DATASET = "pamap2"
LOADER_VERSION = "pamap2-loader-1+pamap2-fill-50ms"
DEFAULT_ROOT = under(HAR_ROOT, "pamap2", "PAMAP2_Dataset")
MAX_FILL = 5
REST_LABELS = ("1", "2", "3")
LEFT_HANDED = {"subject108"}
LABELS = ["0", "1", "10", "11", "12", "13", "16", "17", "18", "19", "2", "20", "24", "3", "4", "5", "6", "7", "9"]


def list_units(root: Optional[str] = None) -> List[str]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    subs = set()
    for part in ("Protocol", "Optional"):
        d = os.path.join(root, part)
        if os.path.isdir(d):
            subs |= {f[:-4] for f in os.listdir(d) if f.startswith("subject") and f.endswith(".dat")}
    return sorted(subs)


def fill_short_dropouts(t: np.ndarray, xyz: np.ndarray, act: np.ndarray, max_fill: int = MAX_FILL):
    """Return (xyz, bad, filled): NaN runs <= max_fill inside one activity interpolated, others flagged bad."""
    xyz = xyz.copy()
    bad = ~np.isfinite(xyz).all(axis=1)
    filled = np.zeros(len(t), bool)
    edges = np.flatnonzero(np.diff(np.r_[0, bad.astype(np.int8), 0]))
    for r0, r1 in zip(edges[::2], edges[1::2]):
        if r1 - r0 <= max_fill and r0 > 0 and r1 < len(t) and act[r0 - 1] == act[r1]:
            for k in range(3):
                xyz[r0:r1, k] = np.interp(t[r0:r1], [t[r0 - 1], t[r1]], [xyz[r0 - 1, k], xyz[r1, k]])
            filled[r0:r1] = True
            bad[r0:r1] = False
    return xyz, bad, filled


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    lut = {n: i for i, n in enumerate(LABELS)}
    for subj in (subjects or list_units(root)):
        for part in ("Protocol", "Optional"):
            path = os.path.join(root, part, f"{subj}.dat")
            if not os.path.isfile(path):
                continue
            a = np.loadtxt(path, usecols=(0, 1, 4, 5, 6), dtype=np.float64)
            if a.ndim != 2 or not len(a):
                raise DatasetError(f"pamap2 file unreadable: {path}")
            t, act = a[:, 0], a[:, 1].astype(int)
            xyz, bad, filled = fill_short_dropouts(t, a[:, 2:5], act)
            keep = ~bad
            names = [str(v) for v in act[keep]]
            unknown = sorted(set(names) - set(lut))
            if unknown:
                raise DatasetError(f"pamap2 {path}: unexpected activity ids {unknown}")
            codes = np.array([lut[n] for n in names], np.int32)
            side = "left" if subj in LEFT_HANDED else "right"
            yield Recording(dataset=DATASET, subject=f"{DATASET}:{subj}", session=f"{DATASET}:{subj}:{part.lower()}",
                            placement=f"wrist_{side}", device="Trivisio Colibri (hand, acc16)", wrist_side=side,
                            axis_frame="Colibri native", source_hz=100.0, t=t[keep], xyz_g=ms2_to_g(xyz[keep]),
                            labels=codes, label_names=list(LABELS), uniform=True, filled=filled[keep],
                            meta={"loader": LOADER_VERSION, "units_native": "m/s^2", "n_dropped_nan": int(bad.sum()),
                                  "filled_fraction": float(filled[keep].mean()) if keep.any() else 0.0})
