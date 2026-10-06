"""Daphnet Freezing of Gait (UCI 245; CC BY 4.0) — **OOD probe only, non-wrist**.

Files ``S##R##.txt``: time (ms), ankle xyz, thigh xyz, trunk xyz (milli-g), annotation (0 outside the
experiment, 1 no freeze, 2 freeze), 64 Hz. The trunk sensor is used (closest to whole-body motion); it is
NOT a wrist placement, so every result on it is informative only and never a Nara wrist claim.
"""

from __future__ import annotations

import glob
import os
from typing import Iterator, List, Optional, Sequence

import numpy as np

from . import HAR_ROOT, Recording, encode_labels, mg_to_g

DATASET = "daphnet_fog"
LOADER_VERSION = "daphnet-loader-1"
DEFAULT_ROOT = os.path.join(HAR_ROOT, "daphnet_fog", "dataset_fog_release", "dataset")
FS = 64.0
REST_LABELS = ("1",)


def list_units(root: Optional[str] = None) -> List[str]:
    root = root or DEFAULT_ROOT
    return sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(root, "S*R*.txt")))


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    root = root or DEFAULT_ROOT
    units = list_units(root)
    if subjects:
        want = set(subjects)
        units = [u for u in units if u in want or u[:3] in want]
    for unit in units:
        a = np.loadtxt(os.path.join(root, f"{unit}.txt"), usecols=(0, 7, 8, 9, 10))
        ok = np.isfinite(a).all(axis=1)
        a = a[ok]
        codes, names = encode_labels(a[:, 4].astype(int))
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{unit[:3]}", session=f"{DATASET}:{unit}",
                        placement="back", device="trunk accelerometer", wrist_side="n/a",
                        axis_frame="trunk sensor native", source_hz=FS, t=a[:, 0] / 1000.0,
                        xyz_g=mg_to_g(a[:, 1:4]), labels=codes, label_names=names, uniform=True,
                        meta={"loader": LOADER_VERSION, "units_native": "milli-g", "role": "ood_only"})
