"""The frozen ActiNet network: strict loading and bounded CPU inference (ACTINET_CLASSIFIER.md §3).

Architecture. This is the network upstream builds with ``torch.hub.load('OxWearables/ssl-wearables:v1.0.0',
'harnet30', class_num=K)``, i.e. ``Resnet(output_size=K, is_eva=True, epoch_len=30, resnet_version=1)``:

- the harnet30 feature extractor, ``float32 [B, 3, 900] -> [B, 1024, 1]``. This is the copy the ActiNet encoder
  lane already vendors (``inertia.vendor.ssl_wearables_resnet``), imported unchanged.
- a head of ``Linear(1024, 512) -> ReLU -> Linear(512, K)`` on the flattened features, giving logits.

The head is Nara's own two-layer definition. Its module names are the ones the checkpoint's keys require
(``classifier.linear1`` / ``classifier.linear2``). The released state dict loads into it strictly: 135 keys, the
same order, every shape and dtype equal.

Inference:
- eval mode, ``torch.inference_mode``, CPU, float32;
- a capped thread count (default 1);
- every batch zero-padded to ``max_batch`` rows, so an epoch's logits never depend on which epochs share its
  request (checked bit-identical in tests);
- NNPACK disabled while it runs. torch otherwise sends the depthwise ``Downsample`` convolution to NNPACK one
  group at a time; the ElderNet lane measured this, see eldernet/model.py.

Probabilities are ``softmax(logits)`` in float64, the transform upstream applies to these logits when it fits the
HMM emission. The released network is uncalibrated, and Nara fits no calibration.
"""

from __future__ import annotations

import contextlib
from typing import Dict, Mapping, Optional

import numpy as np
import torch
import torch.nn as nn

from ..inertia.vendor.ssl_wearables_resnet import HARNET30_DIM, HARNET30_INPUT_SAMPLES, harnet30_feature_extractor
from . import MODEL_SAMPLES
from .weights import WeightsError

HIDDEN = 512
DEFAULT_MAX_BATCH = 64
assert HARNET30_INPUT_SAMPLES == MODEL_SAMPLES


class _Head(nn.Module):
    def __init__(self, n_classes: int):
        super().__init__()
        self.linear1 = nn.Linear(HARNET30_DIM, HIDDEN)
        self.linear2 = nn.Linear(HIDDEN, n_classes)

    def forward(self, z: torch.Tensor) -> torch.Tensor:
        return self.linear2(torch.relu(self.linear1(z)))


class ActiNetNetwork(nn.Module):
    """harnet30 feature extractor + the 1024-512-K head; ``forward`` -> logits ``[B, K]``."""

    def __init__(self, n_classes: int):
        super().__init__()
        if int(n_classes) < 2:
            raise ValueError("need at least two classes")
        self.feature_extractor = harnet30_feature_extractor()
        self.classifier = _Head(int(n_classes))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        z = self.feature_extractor(x)
        return self.classifier(z.view(x.shape[0], -1))


def no_nnpack():
    """``torch.backends.nnpack.flags(enabled=False)`` where this torch build has it, else a no-op."""
    try:
        import torch.backends.nnpack as nnpack
    except ImportError:                    # pragma: no cover - older torch builds
        return contextlib.nullcontext()
    return nnpack.flags(enabled=False)


def load_network(state: Mapping[str, torch.Tensor], n_classes: int) -> ActiNetNetwork:
    """Strict load: identical key set, shapes and dtypes, every floating tensor finite; else ``weights_mismatch``."""
    net = ActiNetNetwork(n_classes)
    want = net.state_dict()
    if not isinstance(state, Mapping):
        raise WeightsError("weights_mismatch", "weights file does not hold a state dict")
    missing, extra = sorted(set(want) - set(state)), sorted(set(state) - set(want))
    if missing or extra:
        raise WeightsError("weights_mismatch", f"state dict does not match the ActiNet network: "
                           f"{len(missing)} missing (e.g. {missing[:3]}), {len(extra)} unexpected (e.g. {extra[:3]})")
    for k, v in state.items():
        if not isinstance(v, torch.Tensor):
            raise WeightsError("weights_mismatch", f"{k}: not a tensor")
        if tuple(v.shape) != tuple(want[k].shape) or v.dtype != want[k].dtype:
            raise WeightsError("weights_mismatch", f"{k}: shape/dtype {tuple(v.shape)}/{v.dtype} != "
                               f"{tuple(want[k].shape)}/{want[k].dtype}")
        if v.is_floating_point() and not bool(torch.isfinite(v).all()):
            raise WeightsError("weights_mismatch", f"{k}: nonfinite values")
    net.load_state_dict(dict(state), strict=True)
    net.eval()
    net.requires_grad_(False)
    return net.to(device="cpu", dtype=torch.float32)


class ActiNetClassifier:
    """A loaded network; ``logits`` float32 ``[B, 3, 900]`` -> float32 ``[B, K]`` in fixed padded batches."""

    def __init__(self, net: nn.Module, n_classes: int, threads: Optional[int] = 1,
                 max_batch: int = DEFAULT_MAX_BATCH):
        if int(max_batch) <= 0:
            raise ValueError("max_batch must be positive")
        if threads is not None and int(threads) > 0:
            torch.set_num_threads(int(threads))
        self.net = net.eval()
        self.n_classes = int(n_classes)
        self.max_batch = int(max_batch)
        self.threads = int(threads) if threads else torch.get_num_threads()

    def logits(self, batch: np.ndarray) -> np.ndarray:
        x = np.asarray(batch)
        if x.ndim != 3 or x.shape[1:] != (3, MODEL_SAMPLES):
            raise ValueError(f"expected [B, 3, {MODEL_SAMPLES}], got {list(x.shape)}")
        if x.dtype != np.float32:
            raise ValueError(f"expected float32 input, got {x.dtype}")
        if not np.isfinite(x).all():
            raise ValueError("nonfinite model input")
        n, mb = x.shape[0], self.max_batch
        out = np.empty((n, self.n_classes), dtype=np.float32)
        if n == 0:
            return out
        with torch.inference_mode(), no_nnpack():
            for i in range(0, n, mb):
                chunk = x[i:i + mb]
                k = chunk.shape[0]
                if k < mb:                                  # fixed batch shape -> batch-independent numerics
                    chunk = np.concatenate([chunk, np.zeros((mb - k,) + chunk.shape[1:], np.float32)], axis=0)
                y = self.net(torch.from_numpy(np.ascontiguousarray(chunk)))
                out[i:i + k] = y.numpy()[:k]
        return out


def softmax(logits: np.ndarray) -> np.ndarray:
    """Row softmax in float64 (max-shifted)."""
    z = np.asarray(logits, dtype=np.float64)
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def build_classifier(state: Mapping[str, torch.Tensor], n_classes: int, threads: Optional[int] = 1,
                     max_batch: int = DEFAULT_MAX_BATCH) -> ActiNetClassifier:
    return ActiNetClassifier(load_network(state, n_classes), n_classes, threads=threads, max_batch=max_batch)


def state_dict_summary(state: Mapping[str, torch.Tensor]) -> Dict[str, int]:
    return {"n_tensors": len(state), "n_parameters": int(sum(int(v.numel()) for v in state.values()))}


__all__ = ["HIDDEN", "DEFAULT_MAX_BATCH", "ActiNetNetwork", "no_nnpack", "load_network", "ActiNetClassifier",
           "softmax", "build_classifier", "state_dict_summary"]
