"""The RecGym checkpoint in the vendored upstream architecture (eval, inference_mode, CPU, fixed batch).

``IMUCNNTransformer(in_channels=6, num_classes=12, d_model=64, n_heads=4, num_layers=2, dropout=0.2)`` exactly as
upstream ``run_experiment`` builds it; the state dict loads strictly (missing, unexpected or reshaped keys are
``weights_mismatch``). Every batch is padded to ``max_batch`` rows, so a window's logits never depend on which other
windows share its batch.
"""

from __future__ import annotations

from typing import Mapping, Optional

import numpy as np
import torch

from ..loaded import no_nnpack
from . import CLASSES, IN_CHANNELS, WINDOW_SAMPLES
from .vendor.imu_transformer import IMUCNNTransformer
from .weights import WeightsError

DEFAULT_MAX_BATCH = 64
ARCHITECTURE = {"in_channels": IN_CHANNELS, "num_classes": len(CLASSES), "d_model": 64, "n_heads": 4,
                "num_layers": 2, "dropout": 0.2}


def build_model() -> torch.nn.Module:
    return IMUCNNTransformer(**ARCHITECTURE)


def read_state_dict(path: str) -> Mapping[str, torch.Tensor]:
    try:
        sd = torch.load(path, map_location="cpu", weights_only=True)
    except Exception as exc:  # noqa: BLE001 - any unreadable checkpoint is a mismatch, never a crash
        raise WeightsError("weights_mismatch", f"{path} is not a loadable state dict: {type(exc).__name__}: {exc}"
                           ) from exc
    if not isinstance(sd, Mapping) or not all(isinstance(v, torch.Tensor) for v in sd.values()):
        raise WeightsError("weights_mismatch", f"{path} does not hold a tensor state dict")
    return sd


def load_strict(model: torch.nn.Module, sd: Mapping[str, torch.Tensor]) -> torch.nn.Module:
    want = model.state_dict()
    missing = sorted(set(want) - set(sd))
    extra = sorted(set(sd) - set(want))
    shape = sorted(k for k in want if k in sd and tuple(sd[k].shape) != tuple(want[k].shape))
    if missing or extra or shape:
        parts = []
        if missing:
            parts.append(f"{len(missing)} missing (e.g. {missing[:3]})")
        if extra:
            parts.append(f"{len(extra)} unexpected (e.g. {extra[:3]})")
        if shape:
            parts.append(f"{len(shape)} shape mismatches (e.g. {shape[:3]})")
        raise WeightsError("weights_mismatch", "checkpoint does not match IMUCNNTransformer(in_channels=6, "
                           "num_classes=12): " + "; ".join(parts))
    model.load_state_dict(dict(sd), strict=True)
    return model.to(device="cpu", dtype=torch.float32).eval()


class RecGymModel:
    """Loaded model; ``logits(scaled)`` maps standardised (N, 80, 6) windows to float64 (N, 12) logits."""

    def __init__(self, model: torch.nn.Module, threads: Optional[int] = 1, max_batch: int = DEFAULT_MAX_BATCH):
        if threads is not None and threads > 0:
            torch.set_num_threads(int(threads))
        self.model = model.eval()
        self.max_batch = int(max_batch)
        if self.max_batch <= 0:
            raise ValueError("max_batch must be positive")

    def logits(self, scaled: np.ndarray) -> np.ndarray:
        x = np.asarray(scaled)
        if x.ndim != 3 or x.shape[1:] != (WINDOW_SAMPLES, IN_CHANNELS):
            raise ValueError(f"expected [N, {WINDOW_SAMPLES}, {IN_CHANNELS}], got {list(x.shape)}")
        n, mb = x.shape[0], self.max_batch
        out = np.empty((n, len(CLASSES)), np.float64)
        if n == 0:
            return out
        # Upstream IMUWindowDataset: torch.from_numpy(X).float(), then (T, C) -> (C, T) per window.
        xc = np.ascontiguousarray(np.swapaxes(x.astype(np.float32), 1, 2))
        with torch.inference_mode(), no_nnpack():
            for i in range(0, n, mb):
                chunk = xc[i:i + mb]
                k = chunk.shape[0]
                if k < mb:
                    chunk = np.concatenate([chunk, np.zeros((mb - k,) + chunk.shape[1:], np.float32)], axis=0)
                out[i:i + k] = self.model(torch.from_numpy(chunk)).double().numpy()[:k]
        return out


def load_model(path: str, threads: Optional[int] = 1, max_batch: int = DEFAULT_MAX_BATCH) -> RecGymModel:
    return RecGymModel(load_strict(build_model(), read_state_dict(path)), threads=threads, max_batch=max_batch)


def softmax(logits: np.ndarray) -> np.ndarray:
    z = np.asarray(logits, dtype=np.float64)
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


__all__ = ["DEFAULT_MAX_BATCH", "ARCHITECTURE", "build_model", "read_state_dict", "load_strict", "RecGymModel",
           "load_model", "softmax"]
