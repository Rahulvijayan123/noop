"""Encoder contract: identity metadata, input contract, the Encoder protocol and typed errors.

Every encoder the Inertia lane can run — the vendored upstream architectures behind
``Inertia1Encoder`` and the offline stand-ins — exposes the same two members:

  ``info``                 an :class:`EncoderInfo` (who am I, which bytes, which input contract)
  ``embed(batch)``         ``float32 [B, 3, T]`` (ax, ay, az in g, gravity kept, 20 Hz) -> ``float32 [B, D]``

``embed`` raises :class:`EncoderInputError` on any contract violation (wrong type/dtype/shape, nonfinite
input). Load-time failures are :class:`InertiaUnavailable` with a kind from a closed set, so the serve
process can report them on the wire without guessing.

Identity rules (INERTIA1.md §2):

* ``encoder_id`` starting with ``inertia-1/`` <=> ``kind == "inertia1"``; ``actinet/`` <=> ``kind ==
  "actinet"``; every other id must start with ``standin:`` and has ``kind == "standin"``.
* ``production_eligible`` only when ``kind`` is ``inertia1`` or ``actinet`` *and* the checkpoint sha256 is a
  verified entry of ``registry.PINNED_CHECKPOINTS`` for that id. ``wire_kind`` — the ``encoder_kind``
  reported on the wire — is the id's kind exactly when production-eligible, otherwise ``"standin"``.

Pure numpy; no torch import here.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import Any, Dict, Mapping, Optional, Protocol, Tuple, runtime_checkable

import numpy as np

from . import (ACTINET_ENCODER_PREFIX, INERTIA_AXES, INERTIA_RATE_HZ, PREPROCESSING_VERSION,
               REAL_ENCODER_PREFIX, STANDIN_PREFIX)

UNAVAILABLE_KINDS: Tuple[str, ...] = ("model_missing", "checkpoint_mismatch", "config_mismatch", "internal")
ENCODER_KINDS: Tuple[str, ...] = ("inertia1", "actinet", "standin")
# kind -> the id prefix that is exactly that kind
KIND_PREFIXES: Dict[str, str] = {"inertia1": REAL_ENCODER_PREFIX, "actinet": ACTINET_ENCODER_PREFIX,
                                 "standin": STANDIN_PREFIX}


def kind_of_id(encoder_id: str) -> Optional[str]:
    for kind, prefix in KIND_PREFIXES.items():
        if isinstance(encoder_id, str) and encoder_id.startswith(prefix):
            return kind
    return None


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class EncoderInputError(ValueError):
    """A batch handed to ``embed`` violates the encoder's input contract (message is safe to surface)."""


class InertiaUnavailable(RuntimeError):
    """The encoder (or its bundle) cannot be used. ``kind`` is one of :data:`UNAVAILABLE_KINDS`."""

    def __init__(self, kind: str, message: str):
        if kind not in UNAVAILABLE_KINDS:
            raise ValueError(f"unknown InertiaUnavailable kind {kind!r}")
        super().__init__(f"{kind}: {message}")
        self.kind = kind
        self.message = message


# ---------------------------------------------------------------------------
# Canonical hashing helpers (shared by encoder configs and bundles)
# ---------------------------------------------------------------------------

def canonical_json_bytes(obj: Any) -> bytes:
    """Deterministic JSON bytes: sorted keys, compact separators, UTF-8, NaN/Inf refused."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str, chunk: int = 1 << 20) -> str:
    """Streamed sha256 of a file (computed before anything parses the file)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def is_sha256_hex(value: Any) -> bool:
    return (isinstance(value, str) and len(value) == 64
            and all(c in "0123456789abcdef" for c in value))


# ---------------------------------------------------------------------------
# Input contract + identity
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class InputContract:
    """What ``embed`` accepts: ``float32 [B, len(axes), window_s * rate_hz]``."""
    window_s: int
    axes: Tuple[str, ...] = INERTIA_AXES
    units: str = "g"
    gravity: str = "kept"
    rate_hz: int = INERTIA_RATE_HZ
    normalization: str = "none"

    @property
    def n_samples(self) -> int:
        return int(self.window_s * self.rate_hz)

    def config_dict(self) -> Dict[str, Any]:
        """The ``input_contract`` object of ``encoder.json`` (window length lives in ``data``)."""
        return {"axes": list(self.axes), "units": self.units, "gravity": self.gravity,
                "rate_hz": self.rate_hz, "normalization": self.normalization}

    def to_dict(self) -> Dict[str, Any]:
        d = self.config_dict()
        d["window_s"] = self.window_s
        return d


@dataclass(frozen=True)
class EncoderInfo:
    """Explicit model/version metadata for one loaded encoder (spec §7)."""
    encoder_id: str
    encoder_version: str
    kind: str
    checkpoint_sha256: Optional[str]
    config: Mapping[str, Any] = field(compare=False)
    config_sha256: str
    embedding_dim: int
    input_contract: InputContract
    extraction_point: str
    upstream_commit: Optional[str] = None
    preprocessing_version: str = PREPROCESSING_VERSION

    def __post_init__(self):
        if self.kind not in ENCODER_KINDS:
            raise ValueError(f"encoder kind must be one of {ENCODER_KINDS}, got {self.kind!r}")
        id_kind = kind_of_id(self.encoder_id)
        if id_kind is None:
            raise ValueError(f"encoder ids must start with one of {sorted(KIND_PREFIXES.values())}: {self.encoder_id!r}")
        if id_kind != self.kind:
            raise ValueError(f"encoder id {self.encoder_id!r} and kind {self.kind!r} disagree "
                             f"(ids starting {KIND_PREFIXES[id_kind]!r} are exactly the {id_kind} kind)")
        if self.checkpoint_sha256 is not None and not is_sha256_hex(self.checkpoint_sha256):
            raise ValueError("checkpoint_sha256 must be 64 lowercase hex chars or None")
        if self.config_sha256 != sha256_bytes(canonical_json_bytes(dict(self.config))):
            raise ValueError("config_sha256 does not match the canonical JSON of config")
        if not isinstance(self.embedding_dim, int) or self.embedding_dim < 1:
            raise ValueError("embedding_dim must be a positive int")
        if self.preprocessing_version != PREPROCESSING_VERSION:
            raise ValueError(f"preprocessing_version must be {PREPROCESSING_VERSION!r}")

    @property
    def production_eligible(self) -> bool:
        """True only for an inertia1 / actinet id whose checkpoint is a verified pinned entry."""
        if self.kind == "standin" or self.checkpoint_sha256 is None:
            return False
        from .registry import PINNED_CHECKPOINTS  # lazy: registry imports adapters
        entry = PINNED_CHECKPOINTS.get(self.checkpoint_sha256)
        return bool(entry) and entry.get("encoder_id") == self.encoder_id

    @property
    def wire_kind(self) -> str:
        """``encoder_kind`` on the wire (INERTIA1.md §2): the id's kind iff production-eligible, else standin."""
        return self.kind if self.production_eligible else "standin"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "encoder_id": self.encoder_id, "encoder_version": self.encoder_version, "kind": self.kind,
            "wire_kind": self.wire_kind, "checkpoint_sha256": self.checkpoint_sha256,
            "config_sha256": self.config_sha256, "embedding_dim": self.embedding_dim,
            "preprocessing_version": self.preprocessing_version,
            "input_contract": self.input_contract.to_dict(), "upstream_commit": self.upstream_commit,
            "extraction_point": self.extraction_point, "production_eligible": self.production_eligible,
        }


def make_info(*, encoder_id: str, kind: str, config: Mapping[str, Any], embedding_dim: int,
              window_s: int, extraction_point: str, checkpoint_sha256: Optional[str] = None,
              upstream_commit: Optional[str] = None, version_tag: str = "") -> EncoderInfo:
    """Build an EncoderInfo, deriving ``config_sha256`` and a deterministic ``encoder_version``."""
    cfg = dict(config)
    cfg_sha = sha256_bytes(canonical_json_bytes(cfg))
    version = f"{version_tag or encoder_id}+cfg.{cfg_sha[:12]}"
    if checkpoint_sha256:
        version += f"+ckpt.{checkpoint_sha256[:12]}"
    return EncoderInfo(encoder_id=encoder_id, encoder_version=version, kind=kind,
                       checkpoint_sha256=checkpoint_sha256, config=cfg, config_sha256=cfg_sha,
                       embedding_dim=int(embedding_dim), input_contract=InputContract(window_s=int(window_s)),
                       extraction_point=extraction_point, upstream_commit=upstream_commit)


@runtime_checkable
class Encoder(Protocol):
    """Frozen, deterministic window encoder."""

    @property
    def info(self) -> EncoderInfo: ...

    def embed(self, batch: np.ndarray) -> np.ndarray: ...


def validate_batch(batch: Any, contract: InputContract) -> np.ndarray:
    """Return ``batch`` if it satisfies ``contract`` exactly; raise EncoderInputError otherwise.

    No silent casting: the dtype must already be float32 and every value finite."""
    if not isinstance(batch, np.ndarray):
        raise EncoderInputError(f"batch must be a numpy array, got {type(batch).__name__}")
    if batch.dtype != np.float32:
        raise EncoderInputError(f"batch dtype must be float32, got {batch.dtype}")
    want = (len(contract.axes), contract.n_samples)
    if batch.ndim != 3 or tuple(batch.shape[1:]) != want:
        raise EncoderInputError(f"batch shape must be [B, {want[0]}, {want[1]}], got {list(batch.shape)}")
    if batch.size and not np.isfinite(batch).all():
        raise EncoderInputError("batch contains nonfinite values")
    return batch
