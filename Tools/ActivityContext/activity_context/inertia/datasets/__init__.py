"""Public-dataset loaders for Inertia head training (one module per dataset).

Every loader yields :class:`Recording` objects: one continuous-clock stream of ONE wrist/forearm (or, for
reference sets, body) accelerometer, **already in g** (m/s^2 / 9.80665, milli-g / 1000 — converted before
any filtering), with the source label of every sample as a code into ``label_names`` (the crosswalk's
``source_label`` strings; ``None`` / null labels are explicit names such as ``"<NA>"`` or ``"0"``).

Loaders never resample, filter or window: :mod:`activity_context.inertia.windows` does that through
``preprocess.resample_to_20hz`` / ``segment_on_gaps`` (INERTIA1.md §3). Loader-specific repairs are
explicit, versioned (``LOADER_VERSION`` per module) and recorded per sample (``filled``):

* PAMAP2 hand IMU: NaN dropouts of <= 5 samples (50 ms) inside one label are linearly filled; longer
  dropouts split the run. Never applied to WHOOP data.
* Irregular-clock watches (WISDM, HHAR): ``uniform=False``; windows.py regrids each run onto the
  nominal rate (linear, runs are split at any step > ``max_step_s``) before resampling.

Physiology columns (PAMAP2 heart rate, MHEALTH ECG) are never parsed.
"""

from __future__ import annotations

import importlib
from dataclasses import dataclass, field
from typing import Any, Dict, Iterator, List, Optional, Sequence

import numpy as np

G = 9.80665
HAR_ROOT = "/Volumes/External SSD/Nara Whoop App V2/research/har-datasets"
LOADERS = {
    "capture24": "capture24", "wisdm2019_watch": "wisdm", "hhar_watch": "hhar", "pamap2": "pamap2",
    "mhealth": "mhealth", "opportunity": "opportunity", "daphnet_fog": "daphnet",
}
TRAIN_WRIST = ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity")


class DatasetError(RuntimeError):
    """A dataset file is missing or does not match the documented format/units."""


@dataclass
class Recording:
    dataset: str
    subject: str                 # namespaced "<dataset>:<subject id>"
    session: str                 # namespaced, unique per recording
    placement: str               # wrist_left | wrist_right | wrist_dominant | wrist_unknown | forearm_* | back...
    device: str
    wrist_side: str              # left | right | unknown | n/a
    axis_frame: str              # device-native frame description (no remap is applied)
    source_hz: float             # nominal rate
    t: np.ndarray                # float64 [N] seconds on the dataset clock (strictly increasing within runs)
    xyz_g: np.ndarray            # float64 [N, 3] in g
    labels: np.ndarray           # int32 [N] index into label_names
    label_names: List[str]
    uniform: bool = True         # samples on a uniform grid at source_hz (else regridded per run)
    max_step_s: Optional[float] = None   # split runs at steps > this (default 1.5 / source_hz, or 1 s)
    filled: Optional[np.ndarray] = None  # bool [N]: sample produced by a documented loader repair
    meta: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self):
        n = len(self.t)
        if self.xyz_g.shape != (n, 3) or self.labels.shape != (n,):
            raise DatasetError(f"{self.session}: inconsistent array shapes")
        if self.filled is not None and self.filled.shape != (n,):
            raise DatasetError(f"{self.session}: filled mask shape mismatch")
        if self.labels.size and (self.labels.min() < 0 or self.labels.max() >= len(self.label_names)):
            raise DatasetError(f"{self.session}: label code out of range")

    @property
    def split_step_s(self) -> float:
        if self.max_step_s is not None:
            return float(self.max_step_s)
        return 1.5 / float(self.source_hz) if self.uniform else 1.0


def ms2_to_g(x: np.ndarray) -> np.ndarray:
    return np.asarray(x, np.float64) / G


def mg_to_g(x: np.ndarray) -> np.ndarray:
    return np.asarray(x, np.float64) / 1000.0


def encode_labels(values: Sequence[Any]) -> tuple:
    """(codes int32, names list[str]) with names sorted for determinism."""
    arr = np.asarray(values).astype(str)
    names, codes = np.unique(arr, return_inverse=True)
    return codes.astype(np.int32), [str(n) for n in names]


def loader(dataset: str):
    if dataset not in LOADERS:
        raise DatasetError(f"no loader for dataset {dataset!r}")
    return importlib.import_module(f".{LOADERS[dataset]}", __name__)


def iter_recordings(dataset: str, root: Optional[str] = None,
                    subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    yield from loader(dataset).iter_recordings(root=root, subjects=subjects)


def list_units(dataset: str, root: Optional[str] = None) -> List[str]:
    """Work units (files/subjects) for parallel loading; ``iter_recordings(subjects=[unit])``."""
    return list(loader(dataset).list_units(root=root))


def rest_median_norm(rec: Recording, rest_labels: Sequence[str]) -> float:
    """Median |a| (g) over samples whose label is a rest posture — the per-dataset unit check (~1 g)."""
    codes = [i for i, n in enumerate(rec.label_names) if n in set(rest_labels)]
    sel = np.isin(rec.labels, codes) & np.isfinite(rec.xyz_g).all(axis=1)
    if not sel.any():
        return float("nan")
    return float(np.median(np.linalg.norm(rec.xyz_g[sel], axis=1)))


__all__ = ["G", "HAR_ROOT", "LOADERS", "TRAIN_WRIST", "DatasetError", "Recording", "ms2_to_g", "mg_to_g",
           "encode_labels", "loader", "iter_recordings", "list_units", "rest_median_norm"]
