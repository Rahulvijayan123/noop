"""Head modules (torch, training only) and their export to the bundle's numpy arrays.

Every head is an **independent** model on the standardised embedding ``z = (emb - mu) / sigma`` (``mu``,
``sigma`` fit on the bundle's train windows). Two architectures (spec §8):

* ``linear``: ``Linear(D, K)``                       -> heads.npz ``<h>.W [K, D]``, ``<h>.b [K]``
* ``mlp``: ``LayerNorm(D) -> Linear(D, 256) -> GELU(erf) -> Dropout(0.2) -> Linear(256, K)``
  -> ``<h>.ln_g``, ``<h>.ln_b`` [D], ``<h>.W1`` [H, D], ``<h>.b1`` [H], ``<h>.W2`` [K, H], ``<h>.b2`` [K]

``K`` is the full class order (unsupported rows are trained as -inf-masked and exported as-is; inference
sets them to -inf). The numpy twins in ``bundle_math`` reproduce these forwards (parity-tested to 1e-6).
The head input is the embedding only — :data:`HEAD_INPUTS` is recorded in every bundle and checked.
"""

from __future__ import annotations

from typing import Dict, Tuple

import numpy as np
import torch
import torch.nn as nn

from . import bundle_math as bm

HEAD_INPUTS = ("embedding",)
MLP_HIDDEN = 256
MLP_DROPOUT = 0.2
ARCHS = ("linear", "mlp")


class LinearHead(nn.Module):
    def __init__(self, d_in: int, k: int):
        super().__init__()
        self.fc = nn.Linear(d_in, k)

    def forward(self, z: torch.Tensor) -> torch.Tensor:
        return self.fc(z)


class MLPHead(nn.Module):
    def __init__(self, d_in: int, k: int, hidden: int = MLP_HIDDEN, dropout: float = MLP_DROPOUT):
        super().__init__()
        self.ln = nn.LayerNorm(d_in, eps=bm.LAYER_NORM_EPS)
        self.fc1 = nn.Linear(d_in, hidden)
        self.act = nn.GELU()                # exact erf GELU (bundle_math.gelu_exact)
        self.drop = nn.Dropout(dropout)
        self.fc2 = nn.Linear(hidden, k)

    def forward(self, z: torch.Tensor) -> torch.Tensor:
        return self.fc2(self.drop(self.act(self.fc1(self.ln(z)))))


def make_head(arch: str, d_in: int, k: int) -> nn.Module:
    if arch == "linear":
        return LinearHead(d_in, k)
    if arch == "mlp":
        return MLPHead(d_in, k)
    raise ValueError(f"unknown head arch {arch!r}")


def export_head(model: nn.Module, name: str, arch: str) -> Dict[str, np.ndarray]:
    """Bundle arrays (float64) for one head, keys ``<name>.<param>`` as bundle_schema expects."""
    def a(t):
        return t.detach().cpu().numpy().astype(np.float64)
    if arch == "linear":
        return {f"{name}.W": a(model.fc.weight), f"{name}.b": a(model.fc.bias)}
    return {f"{name}.ln_g": a(model.ln.weight), f"{name}.ln_b": a(model.ln.bias), f"{name}.W1": a(model.fc1.weight),
            f"{name}.b1": a(model.fc1.bias), f"{name}.W2": a(model.fc2.weight), f"{name}.b2": a(model.fc2.bias)}


def numpy_logits(arrays: Dict[str, np.ndarray], name: str, arch: str, z: np.ndarray) -> np.ndarray:
    """The bundle-side forward (bundle_math) on standardised inputs."""
    if arch == "linear":
        return bm.linear_logits(z, arrays[f"{name}.W"], arrays[f"{name}.b"])
    return bm.mlp_logits(z, *(arrays[f"{name}.{k}"] for k in ("ln_g", "ln_b", "W1", "b1", "W2", "b2")))


def torch_logits(model: nn.Module, z: np.ndarray, batch: int = 8192) -> np.ndarray:
    model.eval()
    out = []
    with torch.no_grad():
        for i in range(0, len(z), batch):
            out.append(model(torch.from_numpy(np.ascontiguousarray(z[i:i + batch], dtype=np.float32))).numpy())
    return np.concatenate(out).astype(np.float64) if out else np.zeros((0, 0))


def fit_standardizer(emb_train: np.ndarray, floor: float = 1e-6) -> Tuple[np.ndarray, np.ndarray]:
    """``std.mu`` / ``std.sigma`` (float64) from TRAIN embeddings; constant features get sigma 1."""
    e = np.asarray(emb_train, np.float64)
    mu = e.mean(axis=0)
    sd = e.std(axis=0)
    return mu, np.where(sd > floor, sd, 1.0)


__all__ = ["HEAD_INPUTS", "ARCHS", "LinearHead", "MLPHead", "make_head", "export_head", "numpy_logits",
           "torch_logits", "fit_standardizer", "MLP_HIDDEN", "MLP_DROPOUT"]
