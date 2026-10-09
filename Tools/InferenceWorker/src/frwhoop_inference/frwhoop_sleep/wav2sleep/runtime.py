"""Bounded model runtime: one cached model per artifact root, one run at a time.

* The model is loaded once per (resolved) artifact root and kept warm; the cache entry records
  the sha256 measured from the loaded bytes.
* At most one wav2sleep run (z-score + forward) executes at a time in this process (a bounded
  semaphore), so a 10-hour night's activations are never multiplied by concurrent requests.
* Both the pinned z-score and the forward run with ``torch.set_num_threads(cap)`` (default 1,
  ``FRWHOOP_WAV2SLEEP_THREADS``, clamped to [1, 4]) and the previous value is restored after.
  The cap covers the z-score too because torch's float32 mean/std reductions are split across
  threads: the same signal can round differently under a different thread count (measured: one
  float32 ulp of the mean). With a fixed cap the output is bit-reproducible; with cap 1 it is
  bit-identical to the pinned code run single-threaded.
* torch's intra-op pool is PROCESS-global: while a run executes, other torch work in the same
  process shares that setting. The Spec 01 runtime should run this provider in its own bounded
  worker process, where the cap is simply the process's cap (integration doc, "Runtime").
* ``torch.inference_mode()``; the input dict holds ONLY ``PPG`` - ECG, ABD and THX are absent,
  the pinned ``predict_on_folder(signals=['PPG'])`` route.
"""

from __future__ import annotations

import os
import threading
from typing import Any

import numpy as np

from . import constants as C
from .artifacts import LoadedModel, load_model

_CACHE: dict[str, LoadedModel] = {}
_CACHE_LOCK = threading.Lock()
_RUN_SLOT = threading.BoundedSemaphore(1)


def thread_cap(value: Any = None) -> int:
    raw = value if value is not None else os.environ.get(C.THREADS_ENV)
    try:
        cap = int(raw) if raw is not None else C.DEFAULT_THREADS
    except (TypeError, ValueError):
        cap = C.DEFAULT_THREADS
    cap = max(1, min(C.MAX_THREADS, cap))
    # Spec 01's bounded worker sets the process-wide math-thread cap; this lane never exceeds it.
    try:
        process_cap = int(os.environ.get("FRWHOOP_INFERENCE_MATH_THREADS", ""))
    except ValueError:
        process_cap = 0
    return min(cap, process_cap) if process_cap >= 1 else cap


def get_model(model_root: str) -> LoadedModel:
    """The warm model for ``model_root`` (verified + strictly loaded on first use)."""
    key = os.path.realpath(model_root)
    with _CACHE_LOCK:
        cached = _CACHE.get(key)
        if cached is not None:
            return cached
        loaded = load_model(key)
        _CACHE[key] = loaded
        return loaded


def clear_cache() -> None:
    with _CACHE_LOCK:
        _CACHE.clear()


def cached_models() -> dict[str, LoadedModel]:
    with _CACHE_LOCK:
        return dict(_CACHE)


def run_ppg(loaded: LoadedModel, signal: np.ndarray, *, threads: int) -> tuple[np.ndarray, dict]:
    """Pinned z-score + forward for one resampled (float32, unnormalized) PPG run.

    Returns ``(logits [n_epochs, 4] as float64 copies of the float32 output, stats)``.
    """
    import torch

    from .preprocessing import normalize

    signal = np.ascontiguousarray(signal, dtype=np.float32)
    if signal.ndim != 1 or signal.size == 0 or signal.size % C.MODEL_SAMPLES_PER_EPOCH:
        raise ValueError("PPG must be 1-D with a whole number of 1024-sample epochs")
    n_epochs = signal.size // C.MODEL_SAMPLES_PER_EPOCH
    if n_epochs > C.MAX_EPOCHS:
        raise ValueError(f"{n_epochs} epochs > the official max sequence {C.MAX_EPOCHS}")
    with _RUN_SLOT:
        previous = torch.get_num_threads()
        torch.set_num_threads(int(threads))
        try:
            source = torch.from_numpy(signal)
            stats = {"mean": float(torch.mean(source)), "std": float(torch.std(source))}
            normalized = normalize(signal)
            with torch.inference_mode():
                logits = loaded.model({C.MODEL_SIGNAL: normalized.reshape(1, -1)})
        finally:
            torch.set_num_threads(previous)
    if tuple(logits.shape) != (1, n_epochs, len(C.CLASS_ORDER)):
        raise ValueError(f"unexpected logits shape {tuple(logits.shape)}")
    stats["threads"] = int(threads)
    return logits[0].detach().cpu().numpy().astype(np.float64), stats


def softmax(logits: np.ndarray) -> np.ndarray:
    """Row softmax in float64 (the class probabilities the CrossEntropyLoss training implies)."""
    shifted = logits - np.max(logits, axis=-1, keepdims=True)
    exp = np.exp(shifted)
    return exp / np.sum(exp, axis=-1, keepdims=True)
