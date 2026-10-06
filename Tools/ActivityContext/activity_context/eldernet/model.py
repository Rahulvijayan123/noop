"""The six ElderNet heads: strict loading and batched CPU inference (ELDERNET.md §1).

The architecture is upstream's own ``models.py`` (``Resnet`` feature extractor + ``ElderNet``), imported verified
from the operator's checkout of the pinned commit (:mod:`.upstream`; Nara's repository holds no Oxford code). Each
head is built as upstream ``gait_quality/weights.py::build_model`` builds it from the ``pipelines/config.yaml``
blocks (ElderNet, head ``fc``, feature_vector_size 128, ReLU between the FC layers), except that the backbone gets
a fresh ``nn.Sequential`` (upstream's ``Resnet`` default argument is one shared instance):

==============  ==============  ======  ======================  ==========
head            output          max_mu  num_layers_regressor    batch_norm
==============  ==============  ======  ======================  ==========
gait_detection  2 logits        —       —                       —
gait_speed      m/s             2.0     0                       False
cadence         steps/min       150     1                       True
gait_length     stride m        2.0     1                       True
regularity      0-1             1.0     1                       False
step_count      steps / 10 s    25      1                       True
==============  ==============  ======  ======================  ==========

Loading is stricter than upstream's ``load_weights`` (which ignores unexpected keys): every model key must be
present with its exact shape, and the only tolerated extra keys are the regression checkpoints' unused
variance head ``regressor.var.{weight,bias}`` (a training-time output the released Regressor no longer has).
``torch.load(weights_only=True)`` only (no pickled code). Inference: eval mode, ``torch.inference_mode``, CPU
float32, a fixed thread count (default 1), every batch padded to ``max_batch`` rows so a window's output never
depends on how many other windows share its request (verified bit-identical in tests/eldernet). NNPACK is
disabled during inference: torch dispatches the depthwise ``Downsample`` conv (groups = channels) to NNPACK one
group at a time, ~15x slower on CPU (27 vs 1.8 ms/window, torch 2.8, 1 thread); outputs differ by ~1e-8.
"""

from __future__ import annotations

from typing import Dict, Mapping, Optional

import numpy as np
import torch

from . import BACKBONE_OUTPUT_SIZE, DETECTION_HEAD, FEATURE_VECTOR_SIZE, HEAD_NAMES, QUALITY_HEADS, WINDOW_S, \
    WINDOW_SAMPLES
from . import upstream
from .weights import WeightsError

def no_nnpack():
    """``torch.backends.nnpack.flags(enabled=False)`` where this torch build has it, else a no-op."""
    import contextlib
    try:
        import torch.backends.nnpack as nnpack
    except ImportError:                    # pragma: no cover - older torch builds
        return contextlib.nullcontext()
    return nnpack.flags(enabled=False)


KNOWN_UNUSED_KEYS = frozenset({"regressor.var.weight", "regressor.var.bias"})
DEFAULT_MAX_BATCH = 64


def build_head(name: str, upstream_dir: Optional[str] = None) -> torch.nn.Module:
    """An un-loaded upstream ElderNet for ``name`` with the upstream architecture settings."""
    if name == DETECTION_HEAD:
        kw = dict(output_size=2, is_classification=True)
    elif name in QUALITY_HEADS:
        _, max_mu, n_layers, bn = QUALITY_HEADS[name]
        kw = dict(output_size=1, is_regression=True, max_mu=max_mu, num_layers_regressor=n_layers, batch_norm=bn)
    else:
        raise KeyError(f"unknown ElderNet head {name!r}")
    up = upstream.models(upstream_dir)
    backbone = up.Resnet(output_size=kw["output_size"], epoch_len=WINDOW_S, feature_extractor=torch.nn.Sequential())
    return up.ElderNet(backbone.feature_extractor, head="fc", non_linearity=True,
                       linear_model_input_size=BACKBONE_OUTPUT_SIZE, linear_model_output_size=FEATURE_VECTOR_SIZE, **kw)


def read_state_dict(path: str, name: str) -> Dict[str, torch.Tensor]:
    try:
        sd = torch.load(path, map_location="cpu", weights_only=True)
    except Exception as exc:  # noqa: BLE001 - any unreadable checkpoint is a mismatch, never a crash
        raise WeightsError("weights_mismatch", f"{name}: {path} is not a loadable state dict: "
                           f"{type(exc).__name__}: {exc}") from exc
    if not isinstance(sd, Mapping) or not all(isinstance(v, torch.Tensor) for v in sd.values()):
        raise WeightsError("weights_mismatch", f"{name}: {path} does not hold a tensor state dict")
    return dict(sd)


def load_strict(model: torch.nn.Module, sd: Mapping[str, torch.Tensor], name: str) -> torch.nn.Module:
    """Load ``sd`` into ``model`` or raise ``weights_mismatch`` naming what differs."""
    want = model.state_dict()
    missing = sorted(set(want) - set(sd))
    extra = sorted(set(sd) - set(want) - KNOWN_UNUSED_KEYS)
    shape = sorted(k for k in want if k in sd and tuple(sd[k].shape) != tuple(want[k].shape))
    if missing or extra or shape:
        parts = []
        if missing:
            parts.append(f"{len(missing)} missing (e.g. {missing[:3]})")
        if extra:
            parts.append(f"{len(extra)} unexpected (e.g. {extra[:3]})")
        if shape:
            parts.append(f"{len(shape)} shape mismatches (e.g. {shape[:3]})")
        raise WeightsError("weights_mismatch", f"{name}: checkpoint does not match the ElderNet {name} "
                           f"architecture: " + "; ".join(parts))
    model.load_state_dict({k: sd[k] for k in want}, strict=True)
    return model.to(device="cpu", dtype=torch.float32).eval()


class ElderNetHeads:
    """Loaded heads; ``detect`` -> logits [B, 2], ``quality`` -> {head: [B]} (float64 numpy)."""

    def __init__(self, models: Mapping[str, torch.nn.Module], threads: Optional[int] = 1,
                 max_batch: int = DEFAULT_MAX_BATCH):
        missing = [n for n in HEAD_NAMES if n not in models]
        if missing:
            raise WeightsError("model_missing", f"heads not loaded: {missing}")
        if threads is not None and threads > 0:
            torch.set_num_threads(int(threads))
        self.models = {n: models[n].eval() for n in HEAD_NAMES}
        self.max_batch = int(max_batch)
        if self.max_batch <= 0:
            raise ValueError("max_batch must be positive")

    def _run(self, name: str, batch: np.ndarray) -> np.ndarray:
        x = np.asarray(batch)
        if x.ndim != 3 or x.shape[1:] not in ((WINDOW_SAMPLES, 3), (3, WINDOW_SAMPLES)):
            raise ValueError(f"expected [B, {WINDOW_SAMPLES}, 3] or [B, 3, {WINDOW_SAMPLES}], got {list(x.shape)}")
        if x.shape[1] != 3:
            x = np.swapaxes(x, 1, 2)
        n = x.shape[0]
        width = 2 if name == DETECTION_HEAD else 1
        if n == 0:
            return np.zeros((0, width), np.float64)
        model, mb = self.models[name], self.max_batch
        out = np.empty((n, width), np.float64)
        with torch.inference_mode(), no_nnpack():
            for i in range(0, n, mb):
                chunk = x[i:i + mb]
                k = chunk.shape[0]
                if k < mb:                                  # fixed batch shape -> batch-independent numerics
                    chunk = np.concatenate([chunk, np.zeros((mb - k,) + chunk.shape[1:], chunk.dtype)], axis=0)
                t = torch.from_numpy(np.ascontiguousarray(chunk, dtype=np.float32))
                out[i:i + k] = model(t).double().numpy()[:k].reshape(k, width)
        return out

    def detect(self, batch: np.ndarray) -> np.ndarray:
        return self._run(DETECTION_HEAD, batch)

    def quality(self, batch: np.ndarray) -> Dict[str, np.ndarray]:
        return {name: self._run(name, batch)[:, 0] for name in QUALITY_HEADS}


def load_heads(paths: Mapping[str, str], threads: Optional[int] = 1, max_batch: int = DEFAULT_MAX_BATCH,
               upstream_dir: Optional[str] = None) -> ElderNetHeads:
    """name -> verified checkpoint path (``weights.resolve``) -> loaded :class:`ElderNetHeads`, the architecture
    from the verified upstream source (``upstream_dir`` or ``$ELDERNET_UPSTREAM_DIR``)."""
    models = {}
    for name in HEAD_NAMES:
        if name not in paths:
            raise WeightsError("model_missing", f"no checkpoint for {name}")
        models[name] = load_strict(build_head(name, upstream_dir), read_state_dict(paths[name], name), name)
    return ElderNetHeads(models, threads=threads, max_batch=max_batch)


__all__ = ["no_nnpack", "KNOWN_UNUSED_KEYS", "DEFAULT_MAX_BATCH", "build_head", "read_state_dict", "load_strict",
           "ElderNetHeads", "load_heads"]
