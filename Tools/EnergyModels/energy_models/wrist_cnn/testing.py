"""Test support (not used at inference time): a tiny network of the same family, an independent
loop-based reference forward pass, and a builder for fake legacy-Keras ``.h5`` files.

The tiny architecture keeps the real structure -- six valid Conv1D+ReLU layers, MaxPooling1D(3)
after conv 2 and 4 (with a remainder so the "floor" behaviour is exercised), global max pooling,
Dense head -- at a size where an explicit per-element convolution is instantaneous.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np

from .fetch import _expected_layers, npz_bytes
from .pins import NpzPin, PinSet, UpstreamFile
from .spec import HEAD_ACTIVATION, HEADS, ArchSpec, head_units

# 71 -> conv 69 -> conv 67 -> pool 22 (1 step dropped) -> 20 -> 18 -> pool 6 -> 4 -> 2 -> global max
TINY_ARCH = ArchSpec(window_samples=71, n_axes=3, kernel_size=3, filters=(4, 5, 6, 7, 8, 9), pool_after=(2, 4), pool_size=3)

_LAYER_PREFIX = {
    "Reshape": "reshape",
    "Conv1D": "conv1d",
    "MaxPooling1D": "max_pooling1d",
    "GlobalMaxPooling1D": "global_max_pooling1d",
    "Dropout": "dropout",
    "Dense": "dense",
}


def random_weights(arch: ArchSpec, units: int, seed: int = 0) -> dict[str, np.ndarray]:
    rng = np.random.default_rng(seed)
    out: dict[str, np.ndarray] = {}
    for key, shape in arch.weight_shapes(units).items():
        if key.endswith("kernel"):
            fan_in = int(np.prod(shape[:-1]))
            out[key] = rng.normal(0.0, np.sqrt(2.0 / fan_in), size=shape).astype(np.float32)
        else:
            out[key] = rng.normal(0.0, 0.1, size=shape).astype(np.float32)
    return out


def random_windows(arch: ArchSpec, n: int, seed: int = 1, scale: float = 1.0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return rng.normal(0.0, scale, size=(n, arch.window_samples, arch.n_axes)).astype(np.float32)


def naive_forward(weights: dict[str, np.ndarray], arch: ArchSpec, head: str, window: np.ndarray) -> np.ndarray:
    """One window [T, 3] -> head output, using only explicit loops in float64 (no im2col, no matmul)."""
    x = np.asarray(window, dtype=np.float64)
    for i in range(1, arch.n_conv + 1):
        ker = np.asarray(weights[f"conv{i}_kernel"], dtype=np.float64)       # [k, cin, cout]
        bias = np.asarray(weights[f"conv{i}_bias"], dtype=np.float64)
        k, cin, cout = ker.shape
        t_out = x.shape[0] - k + 1
        y = np.zeros((t_out, cout))
        for t in range(t_out):
            for o in range(cout):
                acc = float(bias[o])
                for dk in range(k):
                    for c in range(cin):
                        acc += float(x[t + dk, c]) * float(ker[dk, c, o])
                y[t, o] = acc if acc > 0.0 else 0.0
        x = y
        if i in arch.pool_after:
            p = arch.pool_size
            x = np.stack([x[j * p : (j + 1) * p].max(axis=0) for j in range(x.shape[0] // p)])
    feats = x.max(axis=0)
    wd = np.asarray(weights["dense_kernel"], dtype=np.float64)
    bd = np.asarray(weights["dense_bias"], dtype=np.float64)
    z = np.array([float(bd[u]) + sum(float(feats[c]) * float(wd[c, u]) for c in range(wd.shape[0])) for u in range(wd.shape[1])])
    if HEAD_ACTIVATION[head] == "softmax":
        e = np.exp(z - z.max())
        return e / e.sum()
    return z


def write_fake_keras_h5(
    path: Path,
    weights: dict[str, np.ndarray],
    head: str,
    arch: ArchSpec = TINY_ARCH,
    *,
    naming: str = "nested",
    mutate_config=None,
) -> None:
    """Write a legacy-Keras-style ``.h5`` (``model_config`` + ``model_weights``) holding ``weights``.

    ``naming="nested"``: datasets at ``<layer>/<layer>/kernel:0`` like Keras 2.2.4;
    ``"flat"``: ``<layer>/kernel:0``. ``mutate_config(model_config_dict)`` lets a test corrupt the architecture.
    """
    import h5py  # noqa: PLC0415 - build-time dependency, tests importorskip it

    layers = _expected_layers(head, arch)
    counters: dict[str, int] = {}
    cfgs = []
    for cls, cfg in layers:
        base = _LAYER_PREFIX[cls]
        counters[base] = counters.get(base, 0) + 1
        cfgs.append({"class_name": cls, "config": {"name": f"{base}_{counters[base]}", **cfg}})
    model_config = {"class_name": "Sequential", "config": cfgs}
    if mutate_config is not None:
        mutate_config(model_config)

    with h5py.File(path, "w") as f:
        f.attrs["model_config"] = json.dumps(model_config).encode("utf8")
        f.attrs["keras_version"] = b"2.2.4"
        f.attrs["backend"] = b"tensorflow"
        mw = f.create_group("model_weights")
        mw.attrs["layer_names"] = np.array([c["config"]["name"].encode() for c in cfgs])
        conv_i = 0
        for (cls, _), c in zip(layers, cfgs):
            name = c["config"]["name"]
            grp = mw.create_group(name)
            if cls not in ("Conv1D", "Dense"):
                grp.attrs["weight_names"] = np.array([], dtype="S1")
                continue
            if cls == "Conv1D":
                conv_i += 1
                prefix = f"conv{conv_i}"
            else:
                prefix = "dense"
            names = []
            for part in ("kernel", "bias"):
                wname = f"{name}/{part}:0" if naming == "nested" else f"{part}:0"
                grp.create_dataset(wname, data=weights[f"{prefix}_{part}"])
                names.append(wname.encode())
            grp.attrs["weight_names"] = np.array(names)


def fake_upstream(root: Path, arch: ArchSpec = TINY_ARCH, *, naming: str = "nested") -> tuple[PinSet, str, dict[str, dict[str, np.ndarray]]]:
    """Create tiny fake "upstream" ``.h5`` files under ``root`` and the matching pins.

    Returns ``(pins, base_url, weights_by_head)``; ``base_url`` is a ``file://`` URL that
    ``fetch.build_artifacts(..., base_url=..., arch=arch, pins=pins)`` accepts as the upstream.
    """
    weights_by_head: dict[str, dict[str, np.ndarray]] = {}
    upstream: dict[str, UpstreamFile] = {}
    npz: dict[str, NpzPin] = {}
    for n, head in enumerate(HEADS):
        weights = weights_by_head[head] = random_weights(arch, head_units(head), seed=10 + n)
        rel = f"models/{head}/fake_{head}.h5"
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        write_fake_keras_h5(path, weights, head, arch, naming=naming)
        blob = path.read_bytes()
        upstream[head] = UpstreamFile(head, rel, len(blob), hashlib.sha256(blob).hexdigest(), "0" * 40)
        nb = npz_bytes(weights)
        npz[head] = NpzPin(f"fake_{head}_f32.npz", len(nb), hashlib.sha256(nb).hexdigest())
    return PinSet(upstream=upstream, npz=npz), root.as_uri(), weights_by_head
