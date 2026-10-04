"""Model manifest: load, validate, and serve the training/deployment contract.

Spec s6/s7: the manifest records repository commit, checkpoint digest,
dependency versions, channel order/units, sampling rate, window/hop,
preprocessing/scaler digest, label mapping, seed, and calibration/rejection
settings. It is the single source of truth consumed by serve.py, infer.py,
train.py and evaluate.py.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import numpy as np

from . import PREPROCESSING_VERSION
from .preprocess import (CHANNEL_ORDER, HOP_SAMPLES, TARGET_HZ, WINDOW_SAMPLES,
                         N_CHANNELS)

SCHEMA_VERSION = 1

# C10 label mapping: WISDM-19 watch activity letter -> ontology v1 motion label.
WISDM_LABEL_MAPPING: Dict[str, str] = {
    "A": "walking",           # walking
    "B": "running",           # jogging
    "C": "other_movement",    # stairs
    "D": "stationary",        # sitting (posture metadata kept separately)
    "E": "stationary",        # standing
    "F": "stationary",        # typing (low wrist movement; DISAGREEMENT case, C10)
    "G": "other_movement",    # teeth
    "H": "other_movement",    # soup
    "I": "other_movement",    # chips
    "J": "other_movement",    # pasta
    "K": "other_movement",    # drinking
    "L": "other_movement",    # sandwich
    "M": "other_movement",    # kicking
    "O": "other_movement",    # catch
    "P": "other_movement",    # dribbling
    "Q": "stationary",        # writing (low wrist movement; DISAGREEMENT case)
    "R": "stationary",        # clapping (C10 final; inspected in eval)
    "S": "stationary",        # folding (C10 final; inspected in eval)
}

ONTOLOGY_MOTION_LABELS = ("stationary", "walking", "running", "other_movement", "unknown")

DEFAULT_THRESHOLDS = {"max_prob": 0.80, "margin": 0.15}   # spec s8 starting values


@dataclass
class Manifest:
    model_version: str
    preprocessing_version: str = PREPROCESSING_VERSION
    model_kind: str = "baseline"            # "baseline" | "hart"
    schema_version: int = SCHEMA_VERSION
    checkpoint: Dict[str, Any] = field(default_factory=dict)
    scaler: Dict[str, Any] = field(default_factory=dict)
    class_map: List[str] = field(default_factory=lambda: list(ONTOLOGY_MOTION_LABELS))
    thresholds: Dict[str, float] = field(default_factory=lambda: dict(DEFAULT_THRESHOLDS))
    units: Dict[str, str] = field(default_factory=lambda: {
        "input_accel": "g", "input_gyro": "deg/s",
        "train_accel": "g", "train_gyro": "deg/s",
    })
    window: Dict[str, int] = field(default_factory=lambda: {
        "samples": WINDOW_SAMPLES, "hop": HOP_SAMPLES, "hz": TARGET_HZ,
    })
    label_mapping: Dict[str, str] = field(default_factory=lambda: dict(WISDM_LABEL_MAPPING))
    seed: int = 0
    deps: Dict[str, str] = field(default_factory=dict)
    # Optional training provenance (spec s7: split manifest, training-data
    # identifiers). Kept optional so baseline/fixture manifests stay valid.
    split: Optional[Dict[str, Any]] = None
    data: Optional[Dict[str, Any]] = None

    def class_id_to_label(self, class_id: int) -> str:
        if not 0 <= class_id < len(self.class_map):
            raise ValueError(f"class id {class_id} out of range")
        return self.class_map[class_id]

    def to_dict(self) -> Dict[str, Any]:
        out = {
            "schema_version": self.schema_version,
            "model_version": self.model_version,
            "preprocessing_version": self.preprocessing_version,
            "model_kind": self.model_kind,
            "checkpoint": self.checkpoint,
            "scaler": self.scaler,
            "class_map": self.class_map,
            "thresholds": self.thresholds,
            "units": self.units,
            "window": self.window,
            "label_mapping": self.label_mapping,
            "seed": self.seed,
            "deps": self.deps,
        }
        if self.split is not None:
            out["split"] = self.split
        if self.data is not None:
            out["data"] = self.data
        return out


class ManifestError(ValueError):
    """Manifest is missing/incorrect; message is safe to surface."""


def _require(d: Dict[str, Any], key: str, typ) -> Any:
    if key not in d:
        raise ManifestError(f"manifest missing required key '{key}'")
    if not isinstance(d[key], typ):
        raise ManifestError(f"manifest key '{key}' must be {typ.__name__}")
    return d[key]


def validate_manifest(data: Dict[str, Any]) -> Manifest:
    """Validate a parsed manifest dict against the schema; return a Manifest."""
    if not isinstance(data, dict):
        raise ManifestError("manifest must be a JSON object")
    schema = _require(data, "schema_version", int)
    if schema != SCHEMA_VERSION:
        raise ManifestError(f"unsupported manifest schema_version {schema} (expected {SCHEMA_VERSION})")

    m = Manifest(
        model_version=_require(data, "model_version", str),
        preprocessing_version=_require(data, "preprocessing_version", str),
        model_kind=_require(data, "model_kind", str),
        checkpoint=_require(data, "checkpoint", dict),
        scaler=_require(data, "scaler", dict),
        class_map=_require(data, "class_map", list),
        thresholds=_require(data, "thresholds", dict),
        units=_require(data, "units", dict),
        window=_require(data, "window", dict),
        label_mapping=_require(data, "label_mapping", dict),
        seed=_require(data, "seed", int),
        deps=_require(data, "deps", dict),
        split=data.get("split"),
        data=data.get("data"),
    )
    if m.model_kind not in ("baseline", "hart"):
        raise ManifestError(f"model_kind must be 'baseline' or 'hart', got {m.model_kind!r}")
    if not m.class_map or not all(isinstance(c, str) and c for c in m.class_map):
        raise ManifestError("class_map must be a non-empty list of non-empty strings")
    if m.model_kind == "baseline":
        for c in m.class_map:
            if c not in ONTOLOGY_MOTION_LABELS:
                raise ManifestError(
                    f"class_map label {c!r} is not in the ontology {ONTOLOGY_MOTION_LABELS}")
    else:  # hart: head outputs are WISDM-19 class letters A..S
        valid = set(WISDM_LABEL_MAPPING)
        for c in m.class_map:
            if c not in valid:
                raise ManifestError(f"class_map label {c!r} is not a WISDM letter {sorted(valid)}")
    if len(set(m.class_map)) != len(m.class_map):
        raise ManifestError("class_map contains duplicate labels")

    for k in ("max_prob", "margin"):
        v = m.thresholds.get(k)
        if not isinstance(v, (int, float)) or not 0.0 < float(v) <= 1.0:
            raise ManifestError(f"thresholds.{k} must be a probability in (0, 1]")
    if float(m.thresholds["max_prob"]) < float(m.thresholds["margin"]):
        raise ManifestError("thresholds.max_prob must be >= thresholds.margin")

    if m.units.get("input_accel") != "g" or m.units.get("input_gyro") != "deg/s":
        raise ManifestError("units.input must be canonical WHOOP (g, deg/s)")
    if m.units.get("train_accel") not in ("g", "m/s^2") or m.units.get("train_gyro") not in ("deg/s", "rad/s"):
        raise ManifestError("units.train must record the training contract (g/deg/s or m/s^2/rad/s)")

    w = m.window
    if w.get("samples") != WINDOW_SAMPLES or w.get("hop") != HOP_SAMPLES or w.get("hz") != TARGET_HZ:
        raise ManifestError(
            f"window must be {{{WINDOW_SAMPLES},{HOP_SAMPLES},{TARGET_HZ}}}, got {w}")

    for lab in m.label_mapping.values():
        if lab not in ONTOLOGY_MOTION_LABELS:
            raise ManifestError(f"label_mapping value {lab!r} not in ontology")

    if m.split is not None:
        if not isinstance(m.split, dict):
            raise ManifestError("split must be a JSON object when present")
        for key in ("train_subjects", "val_subjects", "test_subjects"):
            lst = m.split.get(key)
            if not isinstance(lst, list) or not all(isinstance(s, int) for s in lst):
                raise ManifestError(f"split.{key} must be a list of subject ints when present")
    if m.data is not None and not isinstance(m.data, dict):
        raise ManifestError("data must be a JSON object when present")

    if m.model_kind == "hart":
        ck = m.checkpoint
        if not ck.get("commit"):
            raise ManifestError("checkpoint.commit required for model_kind=hart")
        files = ck.get("files")
        if not isinstance(files, dict) or not files:
            raise ManifestError("checkpoint.files (dict of {name: {sha256, url, size}}) required")
        for name, info in files.items():
            if not isinstance(info, dict) or not isinstance(info.get("sha256"), str) \
                    or len(info["sha256"]) != 64:
                raise ManifestError(f"checkpoint file {name!r} needs a 64-hex sha256")
        if not isinstance(m.scaler, dict):
            raise ManifestError("scaler required for model_kind=hart")
        if "mean" not in m.scaler or "scale" not in m.scaler:
            raise ManifestError("scaler must embed mean/scale arrays (fit on train subjects only)")
        for kk in ("mean", "scale"):
            arr = m.scaler[kk]
            if not isinstance(arr, list) or len(arr) != N_CHANNELS:
                raise ManifestError(f"scaler.{kk} must be a list of {N_CHANNELS} floats")

    return m


def load_manifest(path: str) -> Manifest:
    """Load + validate manifest.json from disk."""
    if not os.path.isfile(path):
        raise ManifestError(f"manifest not found: {path}")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        raise ManifestError(f"manifest is not valid JSON: {exc}") from exc
    return validate_manifest(data)


def scaler_sha256(mean: List[float], scale: List[float]) -> str:
    """Deterministic digest of the embedded scaler arrays (for the manifest)."""
    payload = json.dumps({"mean": [float(v) for v in mean],
                          "scale": [float(v) for v in scale]},
                         sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def default_manifest(model_version: str = "baseline-v0", model_kind: str = "baseline") -> Manifest:
    """Build a baseline-capable manifest (no checkpoint required)."""
    m = Manifest(model_version=model_version, model_kind=model_kind)
    m.label_mapping = dict(WISDM_LABEL_MAPPING)
    return m


def scaler_array_from_manifest(man: Manifest) -> Optional[np.ndarray]:
    """Return (mean[6], scale[6]) if a scaler is embedded, else None."""
    sc = man.scaler
    if not sc or "mean" not in sc or "scale" not in sc:
        return None
    return np.asarray(sc["mean"], dtype=np.float64), np.asarray(sc["scale"], dtype=np.float64)
