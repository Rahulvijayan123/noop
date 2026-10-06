"""MHEALTH (UCI 319; CC BY 4.0): right-lower-arm Shimmer2 accelerometer (columns 15-17, m/s^2), 50 Hz.

No timestamps in the logs: sample k is at k / 50 s. Column 24 is the activity (0 = null). ECG and the
chest/ankle sensors are not parsed into the recording.
"""

from __future__ import annotations

import os
from typing import Iterator, List, Optional, Sequence

import numpy as np

from . import HAR_ROOT, DatasetError, Recording, encode_labels, ms2_to_g

DATASET = "mhealth"
LOADER_VERSION = "mhealth-loader-1"
DEFAULT_ROOT = os.path.join(HAR_ROOT, "mhealth", "MHEALTHDATASET")
FS = 50.0
REST_LABELS = ("1", "2", "3")


def list_units(root: Optional[str] = None) -> List[str]:
    root = root or DEFAULT_ROOT
    return sorted(f[len("mHealth_"):-4] for f in os.listdir(root) if f.startswith("mHealth_subject") and f.endswith(".log"))


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    root = root or DEFAULT_ROOT
    for subj in (subjects or list_units(root)):
        path = os.path.join(root, f"mHealth_{subj}.log")
        if not os.path.isfile(path):
            raise DatasetError(f"mhealth file missing: {path}")
        a = np.loadtxt(path, usecols=(14, 15, 16, 23), dtype=np.float64)
        ok = np.isfinite(a).all(axis=1)
        a = a[ok]
        codes, names = encode_labels(a[:, 3].astype(int))
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{subj}", session=f"{DATASET}:{subj}",
                        placement="wrist_right", device="Shimmer2 (right lower arm; README: right wrist)", wrist_side="right",
                        axis_frame="Shimmer2 native", source_hz=FS, t=np.flatnonzero(ok).astype(np.float64) / FS,
                        xyz_g=ms2_to_g(a[:, :3]), labels=codes, label_names=names, uniform=True,
                        meta={"loader": LOADER_VERSION, "units_native": "m/s^2"})
