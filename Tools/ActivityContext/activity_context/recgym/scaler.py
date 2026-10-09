"""The reproduced RecGym StandardScaler (RECGYM.md §1.2).

Upstream ``make_loaders_for_channels`` fits ``sklearn.preprocessing.StandardScaler`` on the training windows
flattened to ``(N, 80 * 6)``, so the scaler is per (time step, channel) feature: 480 means and 480 scales, applied as
``(x - mean) / scale`` in float64 before the float32 cast the dataset makes. Upstream did not ship it; the committed
``recgym_wrist_imu_scaler.json`` is the exact refit from the public dataset (``reproduce.py``), with the dataset,
upstream commit, procedure and the reproduced upstream test accuracy inside the file.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any, Dict, Optional

import numpy as np

from . import CHANNELS, CLASSES, SCALER_FILE, SCALER_VERSION, WINDOW_SAMPLES

PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
SCALER_PATH = os.path.join(PACKAGE_DIR, SCALER_FILE)
SCALER_SCHEMA = "recgym-scaler/1"


class ScalerError(ValueError):
    pass


@dataclass(frozen=True)
class RecGymScaler:
    mean: np.ndarray          # (80, 6) float64
    scale: np.ndarray         # (80, 6) float64, all > 0
    version: str
    sha256: str
    document: Dict[str, Any]

    def transform(self, windows: np.ndarray) -> np.ndarray:
        """(N, 80, 6) RecGym-unit windows -> standardised float64, exactly sklearn's ``transform`` on the flattened
        windows (``X -= mean_; X /= scale_``)."""
        x = np.asarray(windows, dtype=np.float64)
        if x.ndim != 3 or x.shape[1:] != (WINDOW_SAMPLES, len(CHANNELS)):
            raise ScalerError(f"expected (N, {WINDOW_SAMPLES}, {len(CHANNELS)}), got {list(x.shape)}")
        flat = x.reshape(len(x), -1).copy()
        flat -= self.mean.reshape(-1)
        flat /= self.scale.reshape(-1)
        return flat.reshape(x.shape)

    def inverse_transform(self, scaled: np.ndarray) -> np.ndarray:
        x = np.asarray(scaled, dtype=np.float64)
        flat = x.reshape(len(x), -1) * self.scale.reshape(-1) + self.mean.reshape(-1)
        return flat.reshape(x.shape)


def load_scaler(path: Optional[str] = None) -> RecGymScaler:
    """Load and check the committed scaler (or ``path``): schema, version, channel and class order, shapes, finite
    values, positive scales."""
    from ..loaded import file_sha256
    p = path or SCALER_PATH
    with open(p, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("schema") != SCALER_SCHEMA:
        raise ScalerError(f"scaler schema {doc.get('schema')!r} != {SCALER_SCHEMA}")
    if path is None and doc.get("scaler_version") != SCALER_VERSION:
        raise ScalerError(f"scaler version {doc.get('scaler_version')!r} != {SCALER_VERSION}")
    if tuple(doc.get("channels") or ()) != CHANNELS or tuple(doc.get("classes") or ()) != CLASSES:
        raise ScalerError("scaler channel or class order differs from the model's")
    mean = np.asarray(doc.get("mean"), dtype=np.float64)
    scale = np.asarray(doc.get("scale"), dtype=np.float64)
    shape = (WINDOW_SAMPLES, len(CHANNELS))
    if mean.shape != shape or scale.shape != shape:
        raise ScalerError(f"scaler mean/scale must be {list(shape)}")
    if not (np.isfinite(mean).all() and np.isfinite(scale).all() and (scale > 0).all()):
        raise ScalerError("scaler values must be finite with positive scales")
    return RecGymScaler(mean=mean, scale=scale, version=str(doc["scaler_version"]), sha256=file_sha256(p),
                        document=doc)


__all__ = ["SCALER_PATH", "SCALER_SCHEMA", "ScalerError", "RecGymScaler", "load_scaler"]
