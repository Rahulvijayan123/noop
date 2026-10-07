"""``eldernet-prep-1``: WHOOP NPB1 raw IMU -> ElderNet 10 s windows at 30 Hz (ELDERNET.md §2).

Pipeline (exact; any change is a new preprocessing version):

1. Accelerometer only: the first 300 i16 of each 600-i16 NPB1 second (ax, ay, az) x 1/4096 -> g, float64.
   Gravity kept; the strap's raw axis frame; no remap, normalisation or clipping. Gyro is decoded (and so
   validated) by the shared HART decoder and then ignored.
2. Runs exactly as the HART path (``activity_context.preprocess.decode_seconds``): duplicate second ->
   error, clock reset -> error, gap > 1 s -> new run. No imputation, no gap bridging, no longest-segment
   selection, no edge-day dropping, no calibration, no non-wear detection; each run on its own.
3. 100 -> 30 Hz per run with upstream's resampler, reproduced exactly: ``actipy.processing.resample`` is
   **nearest-neighbour** (``DatetimeIndex.get_indexer(method='nearest')``; no anti-alias filter anywhere in
   ``pipelines.general``). Output sample k sits at ``run.start_ts + k / 30`` s and copies source sample
   ``round(k * 100 / 30)`` (ties -> the later sample, as pandas; none occur at 100 Hz); ``round((N-1) * 0.3)
   + 1`` output samples, the last clamped to the last input sample (actipy's tick count).
4. 10 s windows (300 samples) on the grid ``start_ts + j * hop_s`` (j >= 0, the REQUEST start), fully inside
   ``[start_ts, end_ts]`` and inside the run. Edge margin 0 s: the nearest-neighbour map has no transient,
   and a window starting at integer second s reads exactly the source samples of [s, s + 10) — so every
   window is a pure function of its own 10 s of raw data (chunking-independent by construction).
5. Model tensor ``[B, 300, 3]`` (float64 here; float32 at the model, as upstream ``run_batch``).

Dataset helpers (:func:`resample_uniform`, :func:`resample_timestamps`) apply the same nearest-neighbour rule
to other source rates on the samples' own clock (upstream instead rounds the sample period to whole
milliseconds in ``acc_to_dataframe``; identical at 100/50/20 Hz, a 0.4-1 % time stretch at 83 or 32 Hz).

Deterministic and pure (no I/O, no RNG, numpy only).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Sequence, Tuple

import numpy as np

from ..preprocess import PreprocessError, Run, decode_seconds
from . import ALLOWED_HOP_S, PREPROCESSING_VERSION, RATE_HZ, WINDOW_S, WINDOW_SAMPLES

SOURCE_HZ = 100
EDGE_MARGIN_S = 0


@dataclass(frozen=True)
class GaitWindow:
    """One model window: integer (or dataset-clock) start/end seconds and ``data`` float64 [300, 3] in g."""
    s: float
    e: float
    data: np.ndarray


def validate_hop(hop_s) -> int:
    if isinstance(hop_s, bool) or not isinstance(hop_s, (int, float)) or float(hop_s) not in ALLOWED_HOP_S:
        raise PreprocessError(f"hop_s must be one of {list(ALLOWED_HOP_S)}, got {hop_s!r}")
    return int(hop_s)


# ---------------------------------------------------------------------------
# Nearest-neighbour resampling (actipy.processing.resample semantics)
# ---------------------------------------------------------------------------

def n_output_samples(n_in: int, fs: float) -> int:
    """actipy's tick count: ``round((n_in - 1) / fs * 30) + 1`` (numpy round-half-even, as ``np.around``)."""
    if n_in <= 0:
        return 0
    return int(np.around((n_in - 1) / float(fs) * RATE_HZ)) + 1


def nearest_index_uniform(n_in: int, fs: float) -> np.ndarray:
    """Source index of each 30 Hz output sample for a uniform source starting at t = 0."""
    m = n_output_samples(n_in, fs)
    k = np.arange(m, dtype=np.int64)
    if float(fs).is_integer():                       # exact rational arithmetic: floor(k * fs / 30 + 1/2)
        idx = (2 * k * int(fs) + RATE_HZ) // (2 * RATE_HZ)
    else:
        idx = np.floor(k * (float(fs) / RATE_HZ) + 0.5).astype(np.int64)
    return np.minimum(idx, n_in - 1)


def resample_uniform(x: np.ndarray, fs: float) -> np.ndarray:
    """Contiguous uniform ``[N, 3]`` g at ``fs`` -> ``[M, 3]`` float64 at 30 Hz (nearest neighbour)."""
    x = np.asarray(x, dtype=np.float64)
    if x.ndim != 2 or x.shape[1] != 3 or x.shape[0] == 0:
        raise PreprocessError(f"signal must be a non-empty [N, 3] array, got shape {x.shape}")
    if not np.isfinite(x).all():
        raise PreprocessError("nonfinite samples rejected")
    if not (np.isfinite(fs) and fs > 0):
        raise PreprocessError(f"invalid source rate {fs!r}")
    if float(fs) == RATE_HZ:
        return x.copy()
    return x[nearest_index_uniform(x.shape[0], fs)]


def nearest_timestamp_index(t: np.ndarray) -> np.ndarray:
    """Source index of each 30 Hz output sample on the grid ``t[0] + k/30`` for ``k <= round((t[-1] - t[0]) * 30)``:
    the nearest source sample by time (ties -> the later one, as pandas ``get_indexer(method='nearest')``)."""
    t = np.asarray(t, dtype=np.float64)
    if t.ndim != 1 or t.size == 0:
        raise PreprocessError("timestamps must be a non-empty 1-D array")
    if t.size > 1 and not (np.diff(t) > 0).all():
        raise PreprocessError("timestamps must be strictly increasing")
    m = int(np.around((t[-1] - t[0]) * RATE_HZ)) + 1
    tq = t[0] + np.arange(m, dtype=np.float64) / RATE_HZ
    right = np.clip(np.searchsorted(t, tq, side="left"), 0, t.size - 1)
    left = np.clip(right - 1, 0, t.size - 1)
    take_left = (tq - t[left]) < (t[right] - tq)
    return np.where(take_left, left, right)


def resample_timestamps(t: np.ndarray, x: np.ndarray) -> np.ndarray:
    """Irregular contiguous source (``t`` seconds, strictly increasing, ``x`` [N, 3] g) -> 30 Hz on the grid
    ``t[0] + k / 30`` by :func:`nearest_timestamp_index`."""
    x = np.asarray(x, dtype=np.float64)
    if x.shape != (np.asarray(t).size, 3):
        raise PreprocessError("timestamps / samples shape mismatch")
    return x[nearest_timestamp_index(t)]


# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------

def window_starts(run_start: float, run_end: float, start_ts: float, end_ts: float, hop_s: int) -> List[float]:
    """Starts on the request grid ``start_ts + j * hop_s`` with the window inside the run and the request."""
    lo = max(start_ts, run_start + EDGE_MARGIN_S)
    hi = min(end_ts, run_end - EDGE_MARGIN_S) - WINDOW_S          # last allowed start
    if hi < lo:
        return []
    j0 = int(np.ceil((lo - start_ts) / hop_s - 1e-9))
    j1 = int(np.floor((hi - start_ts) / hop_s + 1e-9))
    return [start_ts + j * hop_s for j in range(j0, j1 + 1)]


def windows_from_30hz(x30: np.ndarray, t0: float, start_ts: float, end_ts: float, hop_s: int) -> List[GaitWindow]:
    """Window one contiguous 30 Hz run whose sample k sits at ``t0 + k / 30``. Window starts must land on that
    sample grid (``(s - t0) * 30`` integral within 1e-6), otherwise PreprocessError (never interpolated)."""
    hop_s = validate_hop(hop_s)
    run_end = t0 + x30.shape[0] / RATE_HZ
    out: List[GaitWindow] = []
    for s in window_starts(t0, run_end, start_ts, end_ts, hop_s):
        kf = (s - t0) * RATE_HZ
        k = int(round(kf))
        if abs(kf - k) > 1e-6:
            raise PreprocessError(f"window start {s} is not on the run's 30 Hz grid")
        data = x30[k:k + WINDOW_SAMPLES]
        if data.shape != (WINDOW_SAMPLES, 3) or not np.isfinite(data).all():
            raise PreprocessError(f"window at {s} violates the model input contract")
        out.append(GaitWindow(s=s, e=s + WINDOW_S, data=data))
    return out


def run_accel_30hz(run: Run) -> np.ndarray:
    """A decoded WHOOP run -> float64 [30 * T + 1, 3] (ax, ay, az in g) at 30 Hz."""
    return resample_uniform(run.samples[:, 0:3], SOURCE_HZ)


def windows_from_run(run: Run, start_ts: int, end_ts: int, hop_s: int) -> List[GaitWindow]:
    if run.end_ts - run.start_ts < WINDOW_S or run.end_ts <= start_ts or run.start_ts >= end_ts:
        return []
    out = windows_from_30hz(run_accel_30hz(run), run.start_ts, start_ts, end_ts, hop_s)
    return [GaitWindow(s=int(w.s), e=int(w.e), data=w.data) for w in out]


def windows_from_seconds(seconds: Sequence[Tuple[int, np.ndarray]], start_ts: int, end_ts: int,
                         hop_s: int) -> List[GaitWindow]:
    """(ts, int16 columns[600]) seconds -> validated runs -> windows sorted by start."""
    validate_hop(hop_s)
    out: List[GaitWindow] = []
    for run in decode_seconds(seconds):
        out.extend(windows_from_run(run, start_ts, end_ts, hop_s))
    out.sort(key=lambda w: w.s)
    return out


def window_indices(offset_s: float, fs: float) -> np.ndarray:
    """Source indices (relative to the sample at ``t0``) of the 300 samples of a window starting
    ``offset_s`` after ``t0``: nearest neighbour ``round((offset_s + k / 30) * fs)``, ties later."""
    k = np.arange(WINDOW_SAMPLES, dtype=np.int64)
    if float(fs).is_integer() and float(offset_s).is_integer():
        f = int(fs)
        return int(offset_s) * f + (2 * k * f + RATE_HZ) // (2 * RATE_HZ)
    return np.floor((offset_s + k / RATE_HZ) * float(fs) + 0.5).astype(np.int64)


def windows_from_array(acc: np.ndarray, fs: float, hop_s: int = 1, t0: float = 0.0) -> List[GaitWindow]:
    """Offline: a uniform [N, 3] g recording (sample n at ``t0 + n / fs``) -> windows every ``hop_s`` from
    ``t0`` (upstream ``make_windows`` grid at hop 1), each built by the nearest-neighbour rule directly from
    its own samples. Nonfinite samples split the recording; no window spans one (never imputed)."""
    acc = np.asarray(acc, dtype=np.float64)
    if acc.ndim != 2 or acc.shape[1] != 3:
        raise PreprocessError(f"input must be [N, 3], got {acc.shape}")
    if not (np.isfinite(fs) and fs > 0):
        raise PreprocessError(f"invalid source rate {fs!r}")
    hop_s = validate_hop(hop_s)
    out: List[GaitWindow] = []
    for a, b in finite_segments(np.isfinite(acc).all(axis=1)):
        seg_lo, seg_hi = a / float(fs), b / float(fs)            # offsets from t0 covered by the segment
        j0 = int(np.ceil(seg_lo / hop_s - 1e-9))
        j1 = int(np.floor((seg_hi - WINDOW_S) / hop_s + 1e-9))
        for j in range(j0, j1 + 1):
            idx = window_indices(j * hop_s, fs)
            if idx[0] < a or idx[-1] >= b:
                continue
            out.append(GaitWindow(s=t0 + j * hop_s, e=t0 + j * hop_s + WINDOW_S, data=acc[idx]))
    return out


def finite_segments(ok: np.ndarray) -> List[Tuple[int, int]]:
    """[(start, stop)] runs of True (stop exclusive)."""
    ok = np.asarray(ok, dtype=bool)
    if not ok.size:
        return []
    d = np.diff(np.concatenate([[0], ok.astype(np.int8), [0]]))
    return list(zip(np.flatnonzero(d == 1).tolist(), np.flatnonzero(d == -1).tolist()))


def stack_windows(windows: Sequence[GaitWindow]) -> np.ndarray:
    if not windows:
        return np.zeros((0, WINDOW_SAMPLES, 3), dtype=np.float64)
    return np.stack([w.data for w in windows], axis=0)


__all__ = ["PREPROCESSING_VERSION", "SOURCE_HZ", "EDGE_MARGIN_S", "PreprocessError", "GaitWindow", "validate_hop",
           "n_output_samples", "nearest_index_uniform", "resample_uniform", "nearest_timestamp_index", "resample_timestamps",
           "window_starts", "windows_from_30hz", "run_accel_30hz", "windows_from_run", "windows_from_seconds",
           "window_indices", "windows_from_array", "finite_segments", "stack_windows"]
