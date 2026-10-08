"""Artifact verification and model construction for the wav2sleep adapter.

Order, fail-closed at every step:

1. both files must exist under the artifact root at the pinned relative paths;
2. their sizes and sha256 must equal the pins - checked on the bytes BEFORE anything parses or
   unpickles them;
3. ``config.yaml`` is parsed with ``yaml.safe_load`` (the pinned loader uses the full
   ``yaml.CLoader``) and built through an explicit allowlist of the four classes it names,
   instead of ``hydra.utils.instantiate`` (which would import and call any ``_target_``);
4. ``state_dict.pth`` is loaded with ``torch.load(weights_only=True)`` onto CPU; it must be a
   flat mapping of float32 tensors whose keys AND shapes equal the constructed model's
   ``state_dict()`` exactly, and is then loaded with ``load_state_dict(strict=True)``;
5. ``eval()`` and ``requires_grad_(False)``: inference only, nothing is trained or fitted.
"""

from __future__ import annotations

import hashlib
import os
import time
from dataclasses import dataclass, field
from typing import Any, Mapping, Optional

from . import constants as C
from .contract import Withhold

_HASH_CHUNK = 1 << 20

#: The only ``_target_`` strings config.yaml may name, mapped to vendored class names.
_ALLOWED_TARGETS = {
    "wav2sleep.models.wav2sleep.Wav2Sleep": "Wav2Sleep",
    "wav2sleep.models.wav2sleep.SignalEncoders": "SignalEncoders",
    "wav2sleep.models.wav2sleep.MultiModalAttentionEmbedder": "MultiModalAttentionEmbedder",
    "wav2sleep.models.wav2sleep.SequenceCNN": "SequenceCNN",
}


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(_HASH_CHUNK)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def artifact_paths(model_root: str) -> dict[str, str]:
    return {name: os.path.join(model_root, spec["relpath"]) for name, spec in C.ARTIFACTS.items()}


@dataclass(frozen=True)
class VerifiedArtifact:
    name: str
    path: str
    size_bytes: int
    sha256: str

    def to_wire(self) -> dict[str, Any]:
        return {"path": self.path, "size_bytes": self.size_bytes, "sha256": self.sha256}


def verify_artifacts(model_root: str, pins: Optional[Mapping[str, Mapping[str, Any]]] = None
                     ) -> dict[str, VerifiedArtifact]:
    """Size and sha256 of both artifacts against the pins. Raises :class:`Withhold`."""
    pins = pins or C.ARTIFACTS
    verified: dict[str, VerifiedArtifact] = {}
    for name, spec in pins.items():
        path = os.path.join(model_root, spec["relpath"])
        if not os.path.isfile(path):
            raise Withhold("artifact_missing", f"{name} not found at {path}", artifact=name, path=path)
        size = os.path.getsize(path)
        if size != int(spec["size_bytes"]):
            raise Withhold("artifact_size_mismatch",
                           f"{name} is {size} bytes, pinned {spec['size_bytes']}",
                           artifact=name, path=path, size_bytes=size)
        digest = sha256_file(path)
        if digest != spec["sha256"]:
            raise Withhold("artifact_sha256_mismatch",
                           f"{name} sha256 {digest} != pinned {spec['sha256']}",
                           artifact=name, path=path, sha256=digest)
        verified[name] = VerifiedArtifact(name=name, path=path, size_bytes=size, sha256=digest)
    return verified


def _check_hydra_free(node: Any, where: str) -> None:
    if isinstance(node, Mapping):
        for key, value in node.items():
            if not isinstance(key, str):
                raise Withhold("config_mismatch", f"{where}: non-string key {key!r}")
            if key.startswith("_") and key.endswith("_") and key != "_target_":
                raise Withhold("config_mismatch", f"{where}.{key}: unsupported hydra directive")
            _check_hydra_free(value, f"{where}.{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            _check_hydra_free(value, f"{where}[{i}]")
    elif not (node is None or isinstance(node, (str, int, float, bool))):
        raise Withhold("config_mismatch", f"{where}: unsupported value type {type(node).__name__}")


def parse_config(path: str) -> dict[str, Any]:
    """``yaml.safe_load`` + structural checks of the released 4-class, non-causal config."""
    import yaml

    with open(path, "r", encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    if not isinstance(config, dict):
        raise Withhold("config_mismatch", "config.yaml root must be a mapping")
    _check_hydra_free(config, "config")
    if config.get("_target_") != "wav2sleep.models.wav2sleep.Wav2Sleep":
        raise Withhold("config_mismatch", f"unexpected root _target_ {config.get('_target_')!r}")
    if config.get("num_classes") != len(C.CLASS_ORDER):
        raise Withhold("config_mismatch", f"num_classes={config.get('num_classes')!r}, expected 4")
    encoders = config.get("signal_encoders") or {}
    if encoders.get("causal") is not False or (config.get("sequence_mixer") or {}).get("causal") is not False:
        raise Withhold("config_mismatch", "the released checkpoint must be non-causal")
    signal_map = encoders.get("signal_map") or {}
    if signal_map.get(C.MODEL_SIGNAL) != C.MODEL_SIGNAL:
        raise Withhold("config_mismatch", "signal_map must route PPG to its own PPG encoder")
    return config


def build_model(config: Mapping[str, Any]):
    """Construct the vendored modules from the allowlisted config (no hydra, no imports by name)."""
    from ..wav2sleep_vendored.models import wav2sleep as vendored

    def build(node: Any, where: str) -> Any:
        if isinstance(node, Mapping) and "_target_" in node:
            target = node["_target_"]
            class_name = _ALLOWED_TARGETS.get(target)
            if class_name is None:
                raise Withhold("config_mismatch", f"{where}: _target_ {target!r} is not allowlisted")
            kwargs = {key: build(value, f"{where}.{key}") for key, value in node.items()
                      if key != "_target_"}
            return getattr(vendored, class_name)(**kwargs)
        if isinstance(node, Mapping):
            return {key: build(value, f"{where}.{key}") for key, value in node.items()}
        if isinstance(node, list):
            return [build(value, f"{where}[{i}]") for i, value in enumerate(node)]
        return node

    return build(config, "config")


def load_state_dict_strict(model: Any, path: str) -> dict[str, Any]:
    """``torch.load(weights_only=True)`` + exact key/shape/dtype match + strict load."""
    import torch

    state = torch.load(path, map_location="cpu", weights_only=True)
    if not isinstance(state, Mapping) or not state:
        raise Withhold("state_dict_mismatch", "state_dict.pth is not a non-empty mapping")
    expected = model.state_dict()
    missing = sorted(set(expected) - set(state))
    unexpected = sorted(set(state) - set(expected))
    if missing or unexpected:
        raise Withhold("state_dict_mismatch",
                       f"state_dict keys differ: missing={missing[:5]} unexpected={unexpected[:5]} "
                       f"({len(missing)} missing, {len(unexpected)} unexpected)",
                       missing=missing[:20], unexpected=unexpected[:20])
    bad_shape = [key for key in expected
                 if not isinstance(state[key], torch.Tensor)
                 or tuple(state[key].shape) != tuple(expected[key].shape)]
    if bad_shape:
        raise Withhold("state_dict_mismatch",
                       f"state_dict shapes differ for {len(bad_shape)} tensors, e.g. {bad_shape[:3]}",
                       shape_mismatch=bad_shape[:20])
    bad_dtype = [key for key in expected if state[key].dtype != torch.float32]
    if bad_dtype:
        raise Withhold("state_dict_mismatch", f"non-float32 tensors: {bad_dtype[:3]}")
    result = model.load_state_dict(state, strict=True)
    if getattr(result, "missing_keys", None) or getattr(result, "unexpected_keys", None):
        raise Withhold("state_dict_mismatch", "strict load reported missing/unexpected keys")
    return {
        "tensors": len(state),
        "parameters": int(sum(int(t.numel()) for t in state.values())),
        "dtype": "float32",
    }


@dataclass
class LoadedModel:
    model: Any
    artifacts: dict[str, VerifiedArtifact]
    inventory: dict[str, Any]
    load_seconds: float
    loaded_at_unix: float
    config: dict[str, Any] = field(default_factory=dict)

    @property
    def artifact_digest(self) -> str:
        from .digests import artifact_digest

        return artifact_digest({name: a.sha256 for name, a in self.artifacts.items()})


def load_model(model_root: str, pins: Optional[Mapping[str, Mapping[str, Any]]] = None) -> LoadedModel:
    """Verify, build and strictly load. Raises :class:`Withhold` for every artifact fault."""
    started = time.perf_counter()
    verified = verify_artifacts(model_root, pins)
    config = parse_config(verified["config.yaml"].path)
    model = build_model(config)
    inventory = load_state_dict_strict(model, verified["state_dict.pth"].path)
    model.eval()
    model.requires_grad_(False)
    if model.training or any(p.requires_grad for p in model.parameters()):
        raise Withhold("state_dict_mismatch", "model is not in inference-only mode")
    inventory.update({"valid_signals": list(model.valid_signals),
                      "num_classes": int(model.num_classes),
                      "signal_encoders_causal": bool(model.signal_encoders.causal)})
    return LoadedModel(model=model, artifacts=verified, inventory=inventory,
                       load_seconds=round(time.perf_counter() - started, 4),
                       loaded_at_unix=time.time(), config=config)
