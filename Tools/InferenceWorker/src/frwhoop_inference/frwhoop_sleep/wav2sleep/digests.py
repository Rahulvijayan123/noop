"""Digests for cache identity and runtime identity.

``cache_key = sha256(input_digest, artifact_digest, preprocessing_digest)`` where

* ``input_digest``     - the admitted data: window, declared native rate, context identity, each
  run's boundaries and configuration identity, and the raw native samples (int64 little-endian
  bytes). Segment chunking does not change it; any changed sample, boundary, rate or window does.
* ``artifact_digest``  - the weights and config sha256 measured from the bytes that were loaded,
  plus the vendored model code measured from disk. Changed weight bytes invalidate prior answers
  even when a version label is reused.
* ``preprocessing_digest`` - the preprocessing parameters, the active gates (including any
  request override) and the adapter/vendored preprocessing code measured from disk.
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
from typing import Any, Mapping, Optional

import numpy as np

from . import constants as C

_HERE = os.path.dirname(os.path.abspath(__file__))
_VENDORED = os.path.join(os.path.dirname(_HERE), "wav2sleep_vendored")

#: Vendored files that define the model function.
MODEL_CODE_FILES = ("settings.py", "models/__init__.py", "models/wav2sleep.py",
                    "models/blocks.py", "models/utils.py")
#: Files that define the tensor handed to the model.
PREPROCESSING_CODE_FILES = (("adapter", "constants.py"), ("adapter", "contract.py"),
                            ("adapter", "preprocessing.py"), ("vendored", "data/zscore.py"))


def _canonical(payload: Any) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")


def sha256_json(payload: Any) -> str:
    return hashlib.sha256(_canonical(payload)).hexdigest()


def _file_sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


@functools.lru_cache(maxsize=1)
def model_code_files() -> dict[str, str]:
    return {rel: _file_sha256(os.path.join(_VENDORED, rel)) for rel in MODEL_CODE_FILES}


@functools.lru_cache(maxsize=1)
def preprocessing_code_files() -> dict[str, str]:
    out = {}
    for where, rel in PREPROCESSING_CODE_FILES:
        base = _HERE if where == "adapter" else _VENDORED
        out[f"{where}/{rel}"] = _file_sha256(os.path.join(base, rel))
    return out


def model_code_digest() -> str:
    return sha256_json(model_code_files())


def artifact_digest(artifact_sha256: Mapping[str, str]) -> str:
    return sha256_json({"artifacts": dict(artifact_sha256), "model_code": model_code_digest()})


def preprocessing_digest(config: Mapping[str, Any]) -> str:
    from .preprocessing import preprocessing_parameters

    return sha256_json({"parameters": preprocessing_parameters(), "gates": dict(config),
                        "code": preprocessing_code_files()})


def input_digest(night: Any, context: Mapping[str, Any]) -> str:
    """sha256 over the admitted runs (see module docstring)."""
    digest = hashlib.sha256()
    header = {
        "provider_id": C.PROVIDER_ID,
        "window": [night.window_start, night.window_end],
        "native_rate_hz": night.native_rate_hz,
        "context": {key: context.get(key) for key in ("user_id", "device_id", "iana_timezone")},
        "runs": [{"start": run.start, "end": run.end, "config_identity": run.config_identity,
                  "rate_hz": run.rate_hz, "samples": int(run.samples.size)} for run in night.runs],
    }
    digest.update(_canonical(header))
    for run in night.runs:
        digest.update(np.ascontiguousarray(run.samples, dtype="<i8").tobytes())
    return digest.hexdigest()


def cache_key(input_sha: str, artifact_sha: Optional[str], preprocessing_sha: str) -> str:
    material = "\n".join(["wav2sleep-cache/1", input_sha, artifact_sha or "unloaded", preprocessing_sha])
    return hashlib.sha256(material.encode("utf-8")).hexdigest()
