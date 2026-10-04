"""Numpy-only forward pass of the pretrained wrist CNN (regression and 3-class heads).

Layer semantics, verified against the upstream Keras 2.2.4 configs and reproduced
numerically against Keras (see ``verify_keras.py``)::

    input  [n, 6000, 3]  float32, g, gravity included, *upstream layout* (see inputs.py)
    Conv1D(80,  k=10, stride 1, "valid", relu)   -> [n, 5991,  80]
    Conv1D(100, k=10, "valid", relu)             -> [n, 5982, 100]
    MaxPooling1D(3, stride 3, "valid")           -> [n, 1994, 100]   (floor)
    Conv1D(160) , Conv1D(180)                    -> [n, 1976, 180]
    MaxPooling1D(3)                              -> [n,  658, 180]   (2 trailing steps dropped)
    Conv1D(220) , Conv1D(240)                    -> [n,  640, 240]
    GlobalMaxPooling1D                           -> [n, 240]
    Dropout(0.5)                                 -> identity at inference
    Dense(1, linear)  | Dense(3, softmax)        -> MET     | class probabilities

Convolutions are cross-correlations (no kernel flip, Keras convention) computed as
im2col + one float32 GEMM per layer per window, with bias and ReLU applied in place.
"""

from __future__ import annotations

import io
import threading
from collections.abc import Mapping
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import as_strided

from .integrity import default_artifacts_dir, verify_file
from .pins import PINS, PinSet
from .spec import HEAD_ACTIVATION, HEADS, REAL_ARCH, ArchSpec, head_units

DEFAULT_BATCH_SIZE = 16

# NumPy on macOS Accelerate raises spurious divide/over/invalid FP flags from float32 GEMMs even
# when every result is finite; correctness is enforced by the explicit finiteness check below.
_FP_IGNORE = {"divide": "ignore", "over": "ignore", "invalid": "ignore"}


class _Scratch:
    """Per-thread reusable buffers (page-faulting a fresh 19 MB im2col buffer costs more than the GEMM)."""

    def __init__(self) -> None:
        self._bufs: dict[tuple, np.ndarray] = {}

    def get(self, key: tuple, shape: tuple[int, ...], dtype) -> np.ndarray:
        buf = self._bufs.get(key)
        if buf is None or buf.shape != shape or buf.dtype != dtype:
            buf = np.empty(shape, dtype=dtype)
            self._bufs[key] = buf
        return buf


class WristCNN:
    """One pretrained network (a head). The regression and classification heads are separate networks."""

    def __init__(
        self,
        weights: Mapping[str, np.ndarray],
        head: str,
        *,
        arch: ArchSpec = REAL_ARCH,
        dtype=np.float32,
    ) -> None:
        self.head = head
        self.units = head_units(head)
        self.arch = arch
        self.dtype = np.dtype(dtype)
        if self.dtype not in (np.dtype(np.float32), np.dtype(np.float64)):
            raise ValueError("dtype must be float32 (production) or float64 (reference checks)")

        shapes = arch.weight_shapes(self.units)
        missing = sorted(set(shapes) - set(weights))
        extra = sorted(set(weights) - set(shapes))
        if missing or extra:
            raise ValueError(f"weight set mismatch: missing {missing}, unexpected {extra}")
        w: dict[str, np.ndarray] = {}
        for key, want in shapes.items():
            arr = np.asarray(weights[key])
            if arr.shape != want:
                raise ValueError(f"{key}: shape {arr.shape}, expected {want}")
            if not np.isfinite(arr).all():
                raise ValueError(f"{key}: non-finite weights")
            w[key] = np.ascontiguousarray(arr, dtype=self.dtype)
        self._conv_w = [w[f"conv{i}_kernel"].reshape(-1, w[f"conv{i}_kernel"].shape[-1]) for i in range(1, arch.n_conv + 1)]
        self._conv_b = [w[f"conv{i}_bias"] for i in range(1, arch.n_conv + 1)]
        self._dense_w = w["dense_kernel"]
        self._dense_b = w["dense_bias"]
        self._tls = threading.local()

    # ------------------------------------------------------------------ construction

    @classmethod
    def load(
        cls,
        head: str,
        artifacts_dir: Path | str | None = None,
        *,
        pins: PinSet = PINS,
        verify: bool = True,
        arch: ArchSpec = REAL_ARCH,
        dtype=np.float32,
    ) -> WristCNN:
        """Load the converted weights, refusing to run unless their sha256 equals the pin."""
        if head not in HEADS:
            raise ValueError(f"unknown head {head!r}; expected one of {HEADS}")
        art = Path(artifacts_dir) if artifacts_dir is not None else default_artifacts_dir()
        pin = pins.npz[head]
        path = art / pin.filename
        if not path.exists():
            raise FileNotFoundError(
                f"{path} not found. Fetch and convert the pinned upstream weights first: "
                "python -m energy_models.wrist_cnn.fetch  (or scripts/fetch_wrist_cnn.sh)"
            )
        if verify:
            verify_file(path, pin.sha256, pin.size, label=pin.filename)
        # Read once, verify, then parse the same bytes: no window between check and use.
        blob = path.read_bytes()
        with np.load(io.BytesIO(blob), allow_pickle=False) as z:
            weights = {k: z[k] for k in z.files}
        return cls(weights, head, arch=arch, dtype=dtype)

    # ------------------------------------------------------------------ internals

    def _scratch(self) -> _Scratch:
        s = getattr(self._tls, "scratch", None)
        if s is None:
            s = self._tls.scratch = _Scratch()
        return s

    def _conv_relu(self, x: np.ndarray, i: int, scratch: _Scratch) -> np.ndarray:
        """x: [T, C] C-contiguous -> relu(conv_valid(x) + b): [T-K+1, O] (scratch-owned)."""
        k = self.arch.kernel_size
        t, c = x.shape
        length = t - k + 1
        wf = self._conv_w[i]
        cols = scratch.get(("cols", i), (length, k * c), self.dtype)
        np.copyto(cols, as_strided(x, shape=(length, k * c), strides=(c * x.itemsize, x.itemsize), writeable=False))
        out = scratch.get(("conv", i), (length, wf.shape[1]), self.dtype)
        np.matmul(cols, wf, out=out)
        out += self._conv_b[i]
        np.maximum(out, 0, out=out)
        return out

    def _pool(self, x: np.ndarray, tag: int, scratch: _Scratch) -> np.ndarray:
        p = self.arch.pool_size
        length, c = x.shape
        n_out = length // p                                 # "valid": trailing remainder is dropped
        out = scratch.get(("pool", tag), (n_out, c), self.dtype)
        np.max(x[: n_out * p].reshape(n_out, p, c), axis=1, out=out)
        return out

    def _trunk(self, x: np.ndarray, scratch: _Scratch, stages: list | None = None) -> np.ndarray:
        h = x
        for i in range(self.arch.n_conv):
            h = self._conv_relu(h, i, scratch)
            if stages is not None:
                stages.append((f"conv{i + 1}", h.copy()))
            if (i + 1) in self.arch.pool_after:
                h = self._pool(h, i, scratch)
                if stages is not None:
                    stages.append((f"pool_after_conv{i + 1}", h.copy()))
        return h.max(axis=0)                                 # GlobalMaxPooling1D (Dropout: identity)

    def _check_windows(self, windows) -> np.ndarray:
        arr = windows if isinstance(windows, np.ndarray) else np.asarray(windows)
        a = self.arch
        if arr.ndim != 3 or arr.shape[1:] != (a.window_samples, a.n_axes):
            raise ValueError(
                f"windows must have shape [n, {a.window_samples}, {a.n_axes}] "
                f"(upstream layout, g); got {tuple(arr.shape)}"
            )
        if arr.dtype.kind not in "fiu":
            raise ValueError(f"windows must be numeric, got dtype {arr.dtype}")
        return arr

    def _apply_head(self, feats: np.ndarray, probabilities: bool) -> np.ndarray:
        z = feats @ self._dense_w + self._dense_b
        if probabilities and HEAD_ACTIVATION[self.head] == "softmax":
            z = z - z.max(axis=-1, keepdims=True)
            np.exp(z, out=z)
            z /= z.sum(axis=-1, keepdims=True)
        return z

    # ------------------------------------------------------------------ public API

    def forward_stages(self, window) -> list[tuple[str, np.ndarray]]:
        """Per-stage activations of ONE window ([6000, 3]) for parity/debugging (copies)."""
        arr = np.asarray(window, dtype=self.dtype)
        if arr.shape != (self.arch.window_samples, self.arch.n_axes):
            raise ValueError(f"window must have shape {(self.arch.window_samples, self.arch.n_axes)}, got {arr.shape}")
        stages: list[tuple[str, np.ndarray]] = []
        with np.errstate(**_FP_IGNORE):
            feats = self._trunk(np.ascontiguousarray(arr), self._scratch(), stages)
            stages.append(("global_max", feats.copy()))
            stages.append(("dense", self._apply_head(feats, probabilities=False)))
            stages.append(("output", self._apply_head(feats, probabilities=True)))
        return stages

    def predict_raw(
        self,
        windows,
        *,
        batch_size: int = DEFAULT_BATCH_SIZE,
        skip=None,
        on_invalid: str = "raise",
        probabilities: bool = True,
    ) -> np.ndarray:
        """Run the network on ``windows`` [n, 6000, 3] -> [n, units] (NaN rows for skipped windows).

        ``skip``: optional bool [n]; True windows are not computed (NaN output), so a caller can
        run only on candidate non-sedentary minutes. Non-finite input windows raise
        ``ValueError`` (``on_invalid="raise"``) or yield NaN outputs (``on_invalid="nan"``).
        """
        if on_invalid not in ("raise", "nan"):
            raise ValueError("on_invalid must be 'raise' or 'nan'")
        if batch_size < 1:
            raise ValueError("batch_size must be >= 1")
        arr = self._check_windows(windows)
        n = arr.shape[0]
        run = np.ones(n, dtype=bool)
        if skip is not None:
            skip_a = np.asarray(skip, dtype=bool)
            if skip_a.shape != (n,):
                raise ValueError(f"skip must have shape ({n},), got {skip_a.shape}")
            run &= ~skip_a
        finite = np.ones(n, dtype=bool)
        todo = np.flatnonzero(run)
        for s in range(0, len(todo), 256):
            sel = todo[s : s + 256]
            finite[sel] = np.isfinite(arr[sel]).all(axis=(1, 2))
        bad = run & ~finite
        if bad.any():
            if on_invalid == "raise":
                idx = np.flatnonzero(bad)
                raise ValueError(
                    f"{len(idx)} window(s) contain NaN/inf (first indices {idx[:5].tolist()}); "
                    "mask them with skip=..., use prepare_windows(...).valid, or pass on_invalid='nan'"
                )
            run &= finite

        out = np.full((n, self.units), np.nan, dtype=self.dtype)
        idx = np.flatnonzero(run)
        scratch = self._scratch()
        with np.errstate(**_FP_IGNORE):
            for s in range(0, len(idx), batch_size):
                sel = idx[s : s + batch_size]
                batch = np.asarray(arr[sel], dtype=self.dtype)
                feats = np.stack([self._trunk(np.ascontiguousarray(w), scratch) for w in batch])
                out[sel] = self._apply_head(feats, probabilities)
        done = out[idx]
        if not np.isfinite(done).all():
            raise FloatingPointError("non-finite network output for finite input (input magnitude far outside g?)")
        return out

    def predict(self, windows, **kwargs) -> np.ndarray:
        """Regression head -> MET [n]; classification head -> probabilities [n, 3]."""
        out = self.predict_raw(windows, probabilities=True, **kwargs)
        return out[:, 0] if self.units == 1 else out

    def predict_class(self, windows, **kwargs) -> np.ndarray:
        """Classification head -> argmax index [n] (int8, -1 where skipped/invalid)."""
        if self.head != "classification":
            raise ValueError("predict_class is only defined for the classification head")
        p = self.predict_raw(windows, probabilities=True, **kwargs)
        cls = np.full(p.shape[0], -1, dtype=np.int8)
        ok = np.isfinite(p).all(axis=1)
        cls[ok] = p[ok].argmax(axis=1)
        return cls


# ---------------------------------------------------------------------- convenience

_CACHE: dict[tuple[str, str], WristCNN] = {}
_CACHE_LOCK = threading.Lock()


def load_model(head: str, artifacts_dir: Path | str | None = None) -> WristCNN:
    """Cached, digest-verified model for ``head`` (process-wide)."""
    art = str(Path(artifacts_dir) if artifacts_dir is not None else default_artifacts_dir())
    key = (head, art)
    with _CACHE_LOCK:
        model = _CACHE.get(key)
        if model is None:
            model = _CACHE[key] = WristCNN.load(head, art)
        return model


def predict_met(windows, *, artifacts_dir=None, **kwargs) -> np.ndarray:
    """MET estimate per window (raw regression output, not floored at 1 MET)."""
    return load_model("regression", artifacts_dir).predict(windows, **kwargs)


def predict_proba(windows, *, artifacts_dir=None, **kwargs) -> np.ndarray:
    """Class probabilities [n, 3] (upstream order: index 0, 1, 2 = SED, LPA, MVPA)."""
    return load_model("classification", artifacts_dir).predict(windows, **kwargs)
