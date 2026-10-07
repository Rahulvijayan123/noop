"""``inertia-prep-1``: WHOOP NPB1 raw IMU -> Inertia-1 encoder windows (INERTIA1.md §3).

Pipeline (exact; any change is a new preprocessing version):

1. Accelerometer only: the first 300 i16 of each 600-i16 NPB1 second (ax, ay, az) x 1/4096 -> g.
   Gravity kept; the strap's raw axis frame; no remap, normalisation or clipping. Gyro is decoded (and so
   validated) by the shared HART decoder and then ignored.
2. Runs exactly as the HART path (``activity_context.preprocess.decode_seconds``): duplicate second ->
   error, clock reset -> error, gap > 1 s -> new run. Never interpolated across, never concatenated.
3. Per run, float64: ``scipy.signal.butter(4, 10, fs=100)`` + ``filtfilt`` (scipy default padding), then
   ``scipy.signal.resample_poly(x, 20, 100)`` (= 1/5, Kaiser beta 5; the numpy twin
   ``activity_context.preprocess.resample_poly_nd(x, 1, 5)`` agrees to ~1e-16, checked in tests). Cast to
   float32 after resampling. 20 Hz sample k of a run sits at ``run.start_ts + k / 20`` (both filters
   are zero-phase).
4. Windows of ``window_s * 20`` samples on the grid ``start_ts + j * hop_s`` (j >= 0, the REQUEST start),
   fully inside ``[start_ts, end_ts]`` and >= 1 s from either run edge (filter transients). Too-short
   runs yield no windows. ``s``/``e`` are integer unix seconds, ``e = s + window_s``.
5. Encoder tensor ``[B, 3, T]`` float32, channels ax, ay, az (``stack_windows``).

Dataset loaders use the same filter/resampler through :func:`resample_to_20hz` and split their streams
with :func:`segment_on_gaps` (spec §11; INERTIA1.md §3 last paragraph).

Deterministic and pure (no I/O, no RNG).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Sequence, Tuple

import numpy as np
from scipy.signal import butter, filtfilt, resample_poly

from .. import preprocess as hart_pre
from ..preprocess import PreprocessError, Run, decode_seconds
from . import ALLOWED_HOP_S, ALLOWED_WINDOW_S, INERTIA_RATE_HZ, PREPROCESSING_VERSION

SOURCE_HZ = hart_pre.SOURCE_HZ          # 100 Hz WHOOP
TARGET_HZ = INERTIA_RATE_HZ             # 20 Hz
BUTTER_ORDER = 4
BUTTER_CUTOFF_HZ = 10.0
EDGE_MARGIN_S = 1                       # windows stay >= 1 s from either run edge
RATE_SNAP_HZ = 0.05                     # |fs - round(fs)| below this -> treated as integer rate


class SegmentTooShort(PreprocessError):
    """A contiguous segment is too short for the zero-phase filter (``filtfilt`` padding)."""


@dataclass(frozen=True)
class InertiaWindow:
    """One encoder window: integer start/end seconds and ``data`` float32 [3, window_s * 20]."""
    s: int
    e: int
    data: np.ndarray


def validate_window_hop(window_s, hop_s) -> Tuple[int, int]:
    """Return (window_s, hop_s) as ints if allowed, else raise PreprocessError (never rounded)."""
    for name, v, allowed in (("window_s", window_s, ALLOWED_WINDOW_S), ("hop_s", hop_s, ALLOWED_HOP_S)):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or float(v) not in allowed:
            raise PreprocessError(f"{name} must be one of {list(allowed)}, got {v!r}")
    window_s, hop_s = int(window_s), int(hop_s)
    if hop_s > window_s:
        raise PreprocessError(f"hop_s ({hop_s}) must be <= window_s ({window_s})")
    return window_s, hop_s


# ---------------------------------------------------------------------------
# Public helpers (also used by dataset loaders)
# ---------------------------------------------------------------------------

def lowpass_10hz(x: np.ndarray, fs: float) -> np.ndarray:
    """4th-order Butterworth 10 Hz low-pass, zero-phase (filtfilt, scipy default padding), float64."""
    b, a = butter(BUTTER_ORDER, BUTTER_CUTOFF_HZ, fs=float(fs))
    padlen = 3 * max(len(a), len(b))
    if x.shape[0] <= padlen:
        raise SegmentTooShort(f"segment of {x.shape[0]} samples is too short to filter (need > {padlen})")
    return filtfilt(b, a, x, axis=0)


def resample_to_20hz(x: np.ndarray, source_hz: float) -> np.ndarray:
    """Contiguous ``[N, C]`` signal in g at ``source_hz`` -> float32 ``[M, C]`` at 20 Hz.

    Butterworth(4, 10 Hz) filtfilt at the source rate, then ``resample_poly(20, round(fs))`` when the rate
    is integer within 0.05 Hz, else ``np.interp`` onto the 20 Hz grid ``k / 20`` (the 10 Hz filter is the
    anti-alias stage). A 20 Hz source is returned unchanged (10 Hz is its Nyquist). Sources below 20 Hz
    are refused (no upsampling). Sample k of the output sits at time ``k / 20`` s after sample 0.
    """
    x = np.asarray(x, dtype=np.float64)
    if x.ndim != 2 or x.shape[0] == 0:
        raise PreprocessError(f"signal must be a non-empty [N, C] array, got shape {x.shape}")
    if not np.isfinite(x).all():
        raise PreprocessError("nonfinite samples rejected")
    fs = float(source_hz)
    if not math.isfinite(fs) or fs < TARGET_HZ - RATE_SNAP_HZ:
        raise PreprocessError(f"source rate {source_hz!r} Hz is below {TARGET_HZ} Hz (no upsampling)")
    if abs(fs - TARGET_HZ) < RATE_SNAP_HZ:
        return x.astype(np.float32)
    y = lowpass_10hz(x, fs)
    if abs(fs - round(fs)) < RATE_SNAP_HZ:
        out = resample_poly(y, TARGET_HZ, int(round(fs)), axis=0)
    else:
        n = x.shape[0]
        m = int(math.floor((n - 1) * TARGET_HZ / fs + 1e-9)) + 1
        t_in = np.arange(n, dtype=np.float64) / fs
        t_out = np.arange(m, dtype=np.float64) / TARGET_HZ
        out = np.stack([np.interp(t_out, t_in, y[:, c]) for c in range(y.shape[1])], axis=1)
    out = out.astype(np.float32)
    if not np.isfinite(out).all():
        raise PreprocessError("resampling produced nonfinite samples")
    return out


def segment_on_gaps(t: np.ndarray, max_gap_s: float = 1.0) -> List[slice]:
    """Split sample timestamps (seconds) into maximal contiguous segments.

    A new segment starts wherever the step to the next sample is > ``max_gap_s`` (a gap) or <= 0 (a
    duplicate timestamp or clock reset). Never bridges either. Nonfinite timestamps are rejected."""
    t = np.asarray(t, dtype=np.float64)
    if t.ndim != 1:
        raise PreprocessError("timestamps must be 1-D")
    if t.size == 0:
        return []
    if not np.isfinite(t).all():
        raise PreprocessError("nonfinite timestamps rejected")
    d = np.diff(t)
    cuts = np.flatnonzero((d > max_gap_s) | (d <= 0)) + 1
    bounds = [0, *cuts.tolist(), t.size]
    return [slice(a, b) for a, b in zip(bounds[:-1], bounds[1:]) if b > a]


# ---------------------------------------------------------------------------
# WHOOP path
# ---------------------------------------------------------------------------

def run_accel_20hz(run: Run) -> np.ndarray:
    """A decoded WHOOP run -> float32 [n_seconds * 20, 3] (ax, ay, az in g)."""
    return resample_to_20hz(run.samples[:, 0:3], SOURCE_HZ)


def window_starts(run_start: int, run_end: int, start_ts: int, end_ts: int,
                  window_s: int, hop_s: int) -> List[int]:
    """Integer window starts on the request grid satisfying the request and run-edge constraints."""
    lo = max(start_ts, run_start + EDGE_MARGIN_S)
    hi = min(end_ts, run_end - EDGE_MARGIN_S) - window_s          # last allowed start
    if hi < lo:
        return []
    j0 = -((start_ts - lo) // hop_s)                                # ceil((lo - start_ts) / hop_s)
    return list(range(start_ts + j0 * hop_s, hi + 1, hop_s))


def windows_from_run(run: Run, start_ts: int, end_ts: int, window_s: int, hop_s: int) -> List[InertiaWindow]:
    """Window one contiguous run (see module docstring, step 4)."""
    window_s, hop_s = validate_window_hop(window_s, hop_s)
    starts = window_starts(run.start_ts, run.end_ts, start_ts, end_ts, window_s, hop_s)
    if not starts:
        return []
    x20 = run_accel_20hz(run)
    n = window_s * TARGET_HZ
    out: List[InertiaWindow] = []
    for s in starts:
        k = (s - run.start_ts) * TARGET_HZ
        data = np.ascontiguousarray(x20[k:k + n].T)
        if data.shape != (3, n) or not np.isfinite(data).all():
            raise PreprocessError(f"window at {s} violates the encoder input contract")
        out.append(InertiaWindow(s=int(s), e=int(s + window_s), data=data))
    return out


def windows_from_seconds(seconds: Sequence[Tuple[int, np.ndarray]], start_ts: int, end_ts: int,
                         window_s: int = 30, hop_s: int = 5) -> List[InertiaWindow]:
    """(ts, int16 columns[600]) seconds -> validated runs -> Inertia windows, sorted by start."""
    validate_window_hop(window_s, hop_s)
    out: List[InertiaWindow] = []
    for run in decode_seconds(seconds):
        out.extend(windows_from_run(run, start_ts, end_ts, window_s, hop_s))
    out.sort(key=lambda w: w.s)
    return out


def stack_windows(windows: Sequence[InertiaWindow]) -> np.ndarray:
    """Encoder batch float32 [B, 3, T] (B may be 0 only if T is unknown -> shape [0, 3, 0])."""
    if not windows:
        return np.zeros((0, 3, 0), dtype=np.float32)
    return np.stack([w.data for w in windows], axis=0).astype(np.float32, copy=False)


__all__ = ["PREPROCESSING_VERSION", "SOURCE_HZ", "TARGET_HZ", "EDGE_MARGIN_S", "PreprocessError",
           "SegmentTooShort", "InertiaWindow", "validate_window_hop", "lowpass_10hz", "resample_to_20hz",
           "segment_on_gaps", "run_accel_20hz", "window_starts", "windows_from_run", "windows_from_seconds",
           "stack_windows"]
