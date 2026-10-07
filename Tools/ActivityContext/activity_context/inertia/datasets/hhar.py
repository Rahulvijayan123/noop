"""HHAR (UCI 344; CC BY 4.0), smartwatch subset: ``Watch_accelerometer.csv`` (m/s^2).

Each user wore several watches at once (2x LG G watch ~200 Hz, 2x Samsung Gear ~100 Hz, irregular), so the
streams are near-duplicates of the same movement. To avoid duplicated windows **one watch per user** is
used: the device with the most samples (deterministic; ties -> name order). The clock is
``Creation_Time`` (ns, device clock); duplicate timestamps are dropped; runs split at steps > 0.25 s and
are regridded onto the nominal rate (200 Hz LG, 100 Hz Gear) by windows.py. Arm/side are not in the data
-> ``wrist_unknown``. ``gt`` NaN is the explicit null label ``"null"``.
"""

from __future__ import annotations

import os
from typing import Dict, Iterator, List, Optional, Sequence

import numpy as np

from ..paths import under
from . import HAR_ROOT, DatasetError, Recording, encode_labels, ms2_to_g, resolve_root

DATASET = "hhar_watch"
LOADER_VERSION = "hhar-loader-1"
DEFAULT_ROOT = under(HAR_ROOT, "hhar", "Activity recognition exp")
NULL_LABEL = "null"
NOMINAL = {"lgwatch": 200.0, "gear": 100.0}
MAX_STEP_S = 0.25
REST_LABELS = ("sit", "stand")
_CACHE: Dict[str, object] = {}


def _frame(root: str):
    path = os.path.join(root, "Watch_accelerometer.csv")
    if path not in _CACHE:
        import pandas as pd
        if not os.path.isfile(path):
            raise DatasetError(f"hhar file missing: {path}")
        df = pd.read_csv(path, usecols=["Creation_Time", "x", "y", "z", "User", "Model", "Device", "gt"])
        df["gt"] = df["gt"].fillna(NULL_LABEL).astype(str)
        _CACHE.clear()
        _CACHE[path] = df
    return _CACHE[path]


def chosen_devices(root: Optional[str] = None) -> Dict[str, str]:
    df = _frame(resolve_root(root, DEFAULT_ROOT, DATASET))
    counts = df.groupby(["User", "Device"]).size().reset_index(name="n")
    out = {}
    for user, g in counts.groupby("User"):
        g = g.sort_values(["n", "Device"], ascending=[False, True])
        out[str(user)] = str(g.iloc[0]["Device"])
    return out


def list_units(root: Optional[str] = None) -> List[str]:
    return sorted(chosen_devices(root))


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    df = _frame(root)
    dev = chosen_devices(root)
    for user in (subjects or sorted(dev)):
        device = dev[str(user)]
        g = df[(df["User"] == user) & (df["Device"] == device)].sort_values("Creation_Time", kind="stable")
        g = g.drop_duplicates("Creation_Time", keep="first")
        t = g["Creation_Time"].to_numpy(np.int64).astype(np.float64) / 1e9
        xyz = g[["x", "y", "z"]].to_numpy(np.float64)
        ok = np.isfinite(xyz).all(axis=1)
        codes, names = encode_labels(g["gt"].to_numpy()[ok])
        model = "lgwatch" if device.startswith("lgwatch") else "gear"
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{user}", session=f"{DATASET}:{user}:{device}",
                        placement="wrist_unknown", device=device, wrist_side="unknown",
                        axis_frame="Android watch sensor frame", source_hz=NOMINAL[model], t=t[ok],
                        xyz_g=ms2_to_g(xyz[ok]), labels=codes, label_names=names, uniform=False,
                        max_step_s=MAX_STEP_S,
                        meta={"loader": LOADER_VERSION, "units_native": "m/s^2", "device_rule": "most samples per user",
                              "n_samples_device": int(len(g))})
