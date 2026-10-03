"""WHOOP/NPB1 raw-IMU preprocessing: decode -> float tensor, resample, window.

Canonical source of truth for the model input contract (spec-14 s6, C7/C10):

* WHOOP 5/MG 1244-byte frames decode with the exact offsets/scales of
  Whoop5RawImu.swift:61-103 (frame-absolute: ts @15 u32 LE, countA @24,
  ax/ay/az @28/@228/@428, countB @630, gx/gy/gz @640/@840/@1040; accel
  1/4096 g/LSB, gyro 2000/32768 dps/LSB). Columnar i16 LE, 100 Hz.
* NPB1 rawImuSession columns are the same 600 i16 axis-major per second
  (PushBinaryCodec.packImuRecords, Kind.rawImuSession=4); the 1244-byte
  frame is the on-wire parent these columns are extracted from.
* 100 -> 30 Hz via anti-alias polyphase FIR with ratio 3/10. numpy-only:
  the implementation below reproduces scipy.signal.resample_poly(x, 3, 10)
  bit-for-bit (verified to ~1e-16 on random inputs) so the HART reference
  pipeline (data_preprocessing/Resampling.py, which calls resample_poly)
  and this offline package agree, without a scipy runtime dependency.
* Gravity is PRESERVED: the resampler is a plain low-pass; no high-pass,
  no gravity removal anywhere in preprocessing. (The *baseline classifier*
  removes DC from accel magnitude only as an internal feature.)
* Windows: 120 samples @ 30 Hz (4 s), hop 60 (2 s). Only windows fully
  inside [start_ts, end_ts] and outside the FIR transient region of the
  contiguous run are emitted.
* Gaps/clock resets split runs; separated recordings are never concatenated
  and missing seconds are never zero-filled (spec s6).

All public functions are deterministic and pure (no I/O, no RNG).
"""

from __future__ import annotations

import base64
import struct
from dataclasses import dataclass, field
from typing import Iterable, List, Optional, Sequence, Tuple

import numpy as np

# ---------------------------------------------------------------------------
# Canonical constants (mirror Whoop5RawImu.swift + NPB1 rawImuSession)
# ---------------------------------------------------------------------------

CHANNEL_ORDER: Tuple[str, ...] = ("ax", "ay", "az", "gx", "gy", "gz")
N_CHANNELS = 6

WHOOP_FRAME_BYTES = 1244          # Whoop5RawImu.bufferLength
WHOOP_SAMPLE_COUNT = 100          # samples per frame (1 s @ 100 Hz)
WHOOP_ACCEL_SCALE = 1.0 / 4096.0  # g per LSB
WHOOP_GYRO_SCALE = 2000.0 / 32768.0  # deg/s per LSB (+-2000 dps)

# Frame-absolute offsets (8-byte puffin envelope + payload).
_TS_OFF = 15
_COUNT_A_OFF = 24
_AX_OFF, _AY_OFF, _AZ_OFF = 28, 228, 428
_COUNT_B_OFF = 630
_GX_OFF, _GY_OFF, _GZ_OFF = 640, 840, 1040
_COLUMN_OFFSETS = (_AX_OFF, _AY_OFF, _AZ_OFF, _GX_OFF, _GY_OFF, _GZ_OFF)

# NPB1 columns blob: 600 i16 axis-major per second (1200 bytes).
COLUMNS_PER_SECOND = WHOOP_SAMPLE_COUNT * N_CHANNELS          # 600
COLUMNS_BYTES_PER_SECOND = COLUMNS_PER_SECOND * 2             # 1200

# Sampling / windowing contract.
SOURCE_HZ = 100
TARGET_HZ = 30
WINDOW_SAMPLES = 120            # 4 s @ 30 Hz
HOP_SAMPLES = 60                # 2 s @ 30 Hz
WINDOW_SECONDS = WINDOW_SAMPLES / TARGET_HZ                   # 4.0
HOP_SECONDS = HOP_SAMPLES / TARGET_HZ                         # 2.0
TRANSIENT_MARGIN_SECONDS = 1.0  # FIR half-length (100 input samples) at run edges

# Serve-protocol limits (strict bounded payload checks, C10).
MAX_HEAD_SECONDS = 3
MAX_TAIL_SECONDS = 3
MAX_RUN_SECONDS = 7 * 24 * 3600   # hard cap: a week of seconds per request

_CANONICAL_UNITS = {"accel": "g", "gyro": "deg/s"}


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class PreprocessError(ValueError):
    """Malformed / nonfinite / unsupported input; message is safe to surface."""


# ---------------------------------------------------------------------------
# WHOOP frame decode (golden-format 100 Hz frame -> 600 i16 columns)
# ---------------------------------------------------------------------------

def decode_frame_bytes(frame: bytes) -> Tuple[int, np.ndarray]:
    """Decode one 1244-byte WHOOP 5/MG raw-IMU frame.

    Returns (base_ts, columns) where columns is int16 shape (600,) axis-major
    [ax x100, ay x100, az x100, gx x100, gy x100, gz x100] — the exact twin of
    Whoop5RawImu.rawColumns (Whoop5RawImu.swift:96-103) and of the NPB1
    rawImuSession record blob.
    """
    if not isinstance(frame, (bytes, bytearray)) or len(frame) != WHOOP_FRAME_BYTES:
        raise PreprocessError(
            f"WHOOP IMU frame must be exactly {WHOOP_FRAME_BYTES} bytes, got {len(frame)}")
    if _u16(frame, _COUNT_A_OFF) != WHOOP_SAMPLE_COUNT or _u16(frame, _COUNT_B_OFF) != WHOOP_SAMPLE_COUNT:
        raise PreprocessError("WHOOP IMU frame sample-count gate failed (countA/countB != 100)")
    base_ts = _u32(frame, _TS_OFF)
    cols = np.empty(COLUMNS_PER_SECOND, dtype=np.int16)
    for c, off in enumerate(_COLUMN_OFFSETS):
        cols[c * WHOOP_SAMPLE_COUNT:(c + 1) * WHOOP_SAMPLE_COUNT] = np.frombuffer(
            bytes(frame[off:off + 2 * WHOOP_SAMPLE_COUNT]), dtype="<i2")
    return base_ts, cols


def decode_frame_hex(hex_str: str) -> Tuple[int, np.ndarray]:
    """Decode a golden fixture frame given as a hex string (1244 bytes)."""
    if not isinstance(hex_str, str) or len(hex_str) != WHOOP_FRAME_BYTES * 2:
        raise PreprocessError("golden IMU frame must be a 2488-char hex string")
    try:
        frame = bytes.fromhex(hex_str)
    except ValueError as exc:
        raise PreprocessError("golden IMU frame is not valid hex") from exc
    return decode_frame_bytes(frame)


def raw_columns_to_samples(cols: np.ndarray,
                           accel_scale: float = WHOOP_ACCEL_SCALE,
                           gyro_scale: float = WHOOP_GYRO_SCALE) -> np.ndarray:
    """Convert 600 int16 axis-major columns to float samples (100, 6).

    Output columns follow CHANNEL_ORDER (ax, ay, az, gx, gy, gz) in canonical
    WHOOP units (g, deg/s). Scales are constants applied at read time, exactly
    as Whoop5RawImu.decode does; nothing lossy is baked into the bytes.
    """
    if not isinstance(cols, np.ndarray) or cols.shape != (COLUMNS_PER_SECOND,):
        raise PreprocessError(f"columns must be shape ({COLUMNS_PER_SECOND},), got {cols.shape}")
    if cols.dtype != np.int16:
        cols = cols.astype(np.int16)
    x = cols.astype(np.float64)
    acc = x[0:300].reshape(3, WHOOP_SAMPLE_COUNT) * accel_scale
    gyr = x[300:600].reshape(3, WHOOP_SAMPLE_COUNT) * gyro_scale
    out = np.empty((WHOOP_SAMPLE_COUNT, N_CHANNELS), dtype=np.float64)
    out[:, 0:3] = acc.T
    out[:, 3:6] = gyr.T
    return out


def decode_columns_b64(b64_str: str) -> np.ndarray:
    """Decode one per-second NPB1 columns blob (base64 of 1200 bytes i16 LE)."""
    if not isinstance(b64_str, str):
        raise PreprocessError("columns_b64 entry must be a base64 string")
    try:
        raw = base64.b64decode(b64_str, validate=True)
    except (ValueError, TypeError) as exc:
        raise PreprocessError("columns_b64 entry is not valid base64") from exc
    if len(raw) != COLUMNS_BYTES_PER_SECOND:
        raise PreprocessError(
            f"columns_b64 must decode to {COLUMNS_BYTES_PER_SECOND} bytes "
            f"(600 i16 LE), got {len(raw)}")
    return np.frombuffer(raw, dtype="<i2").astype(np.int16, copy=False)


def encode_columns_b64(cols: np.ndarray) -> str:
    """Inverse of decode_columns_b64 (used by tests)."""
    if cols.shape != (COLUMNS_PER_SECOND,):
        raise ValueError(f"expected ({COLUMNS_PER_SECOND},) int16 columns")
    return base64.b64encode(np.asarray(cols, dtype="<i2").tobytes()).decode("ascii")


def _u16(b, o):  # little-endian
    return int(b[o]) | (int(b[o + 1]) << 8)

def _u32(b, o):  # little-endian
    return int(b[o]) | (int(b[o + 1]) << 8) | (int(b[o + 2]) << 16) | (int(b[o + 3]) << 24)


# ---------------------------------------------------------------------------
# 100 -> 30 Hz anti-alias polyphase FIR (numpy-only; matches scipy 1e-16)
# ---------------------------------------------------------------------------
#
# Filter design (identical to scipy.signal.resample_poly default, which is
# what HART's data_preprocessing/Resampling.py calls):
#
#   up = 3, down = 10                       (ratio 3/10; gcd 1)
#   max_rate = max(up, down) = 10
#   f_c = 1 / max_rate = 0.1                (cutoff, relative to Nyquist of the
#                                            upsampled 300 Hz stream = 15 Hz)
#   half_len = 10 * max_rate = 100
#   taps = 2 * half_len + 1 = 201           (Kaiser windowed-sinc low-pass)
#   h = f_c * sinc(f_c * m)                 (ideal low-pass band [0, f_c])
#   h *= kaiser(beta=5.0)                   (symmetric window)
#   h /= h.sum()                            (unit DC gain, firwin scale=True)
#   h *= up                                 (upsampler gain compensation)
#
# Polyphase application: zero-stuff by 3, full linear convolution with the
# zero-padded filter (n_pre_pad=10 leading zeros, center crop at
# n_pre_remove=11 output samples), decimate by 10. Output sample k maps to
# input time k * down / up samples (= k/30 s) with the filter's fixed ~17 ms
# group delay; documented, negligible for 4 s windows.
#
# The identical design is validated against scipy.signal.resample_poly in
# tests/test_preprocess.py (max abs diff ~1e-16), so offline and HART-pipeline
# results agree to machine precision.

_RESAMPLE_UP = 3
_RESAMPLE_DOWN = 10
_RESAMPLE_HALF_LEN = 10 * max(_RESAMPLE_UP, _RESAMPLE_DOWN)  # 100


def _design_resample_filter(up: int = _RESAMPLE_UP, down: int = _RESAMPLE_DOWN) -> np.ndarray:
    """Return the 201-tap anti-alias FIR (already * up) for ratio up/down."""
    max_rate = max(up, down)
    f_c = 1.0 / max_rate
    half_len = 10 * max_rate
    numtaps = 2 * half_len + 1
    alpha = (numtaps - 1) / 2.0
    m = np.arange(numtaps, dtype=np.float64) - alpha
    h = f_c * np.sinc(f_c * m)                      # ideal low-pass [0, f_c]
    win = np.i0(5.0 * np.sqrt(np.maximum(0.0, 1.0 - (m / alpha) ** 2))) / np.i0(5.0)
    h = h * win
    h = h / h.sum()                                 # unit DC gain
    h = h * up
    return h


def resample_poly_nd(x: np.ndarray, up: int, down: int, axis: int = 0) -> np.ndarray:
    """Generic anti-alias polyphase FIR resample by `up`/`down` (numpy-only).

    Same windowed-sinc design as scipy.signal.resample_poly(x, up, down):
    Kaiser(beta=5.0) low-pass at cutoff 1/max(up,down) Nyquist of the
    upsampled stream, 20*max(up,down)+1 taps, unit DC gain, *up gain, then
    zero-stuff / convolve / decimate with the standard center crop. Matches
    scipy to ~1e-16 (verified in tests).
    """
    x = np.asarray(x, dtype=np.float64)
    if up != int(up) or down != int(down) or up < 1 or down < 1:
        raise PreprocessError("up/down must be positive integers")
    up, down = int(up), int(down)
    n_in = x.shape[axis]
    if n_in == 0:
        raise PreprocessError("cannot resample an empty signal")
    n_out = (n_in * up) // down + bool((n_in * up) % down)
    h = _design_resample_filter(up, down)

    half_len = (len(h) - 1) // 2
    n_pre_pad = down - (half_len % down)
    n_pre_remove = (half_len + n_pre_pad) // down
    h_padded = np.concatenate([np.zeros(n_pre_pad, dtype=np.float64), h])

    # Move resampled axis to the front, process each channel independently.
    xm = np.moveaxis(x, axis, 0)          # (n_in, ...)
    shape = xm.shape[1:]
    flat = xm.reshape(n_in, -1)           # (n_in, C)
    out = np.empty((n_out, flat.shape[1]), dtype=np.float64)
    x_up = np.zeros((n_in - 1) * up + 1, dtype=np.float64)
    for c in range(flat.shape[1]):
        x_up[::up] = flat[:, c]
        y_full = np.convolve(x_up, h_padded)
        idx = (np.arange(n_out) + n_pre_remove) * down
        out[:, c] = y_full[idx]
    out = out.reshape((n_out,) + shape)
    return np.moveaxis(out, 0, axis)


def resample_3_10(x: np.ndarray, axis: int = 0) -> np.ndarray:
    """Resample along `axis` from 100 Hz to 30 Hz (ratio 3/10)."""
    return resample_poly_nd(x, _RESAMPLE_UP, _RESAMPLE_DOWN, axis=axis)


def resample_run_30hz(samples: np.ndarray) -> np.ndarray:
    """Resample a contiguous run of float samples (T, 6) at 100 Hz to 30 Hz."""
    if samples.ndim != 2 or samples.shape[1] != N_CHANNELS:
        raise PreprocessError(f"samples must be (T, {N_CHANNELS}), got {samples.shape}")
    return resample_3_10(samples, axis=0)


# ---------------------------------------------------------------------------
# Runs, gaps, windowing
# ---------------------------------------------------------------------------

@dataclass
class Run:
    """A contiguous (gap-free, duplicate-free) span of decoded seconds."""
    start_ts: int                     # integer unix second of first second
    samples: np.ndarray               # (T*100, 6) float64 in g / deg/s
    end_ts: int                       # exclusive last second

    @property
    def n_seconds(self) -> int:
        return self.end_ts - self.start_ts

    def resampled(self) -> np.ndarray:
        return resample_run_30hz(self.samples)


def _asof_split(seconds: Sequence[Tuple[int, np.ndarray]],
                ) -> List[Tuple[int, np.ndarray]]:
    """Group (ts, columns) pairs into contiguous runs.

    Splits on gaps > 1 s; raises on duplicate timestamps, non-monotonic
    (clock-reset) timestamps, and malformed column payloads."""
    runs: List[Tuple[int, np.ndarray]] = []
    cur_start: Optional[int] = None
    cur_cols: List[np.ndarray] = []
    prev_ts: Optional[int] = None
    for ts, cols in seconds:
        if not isinstance(ts, int) or ts < 0:
            raise PreprocessError(f"invalid second timestamp {ts!r}")
        if cols is None or not isinstance(cols, np.ndarray) or cols.shape != (COLUMNS_PER_SECOND,):
            raise PreprocessError(f"columns for second {ts} are malformed")
        # Canonical NPB1 columns are int16; float input is rejected here so
        # nonfinite values (NaN/Inf) can never be silently cast to a valid
        # window (spec s6: reject nonfinite; int16 cannot encode NaN).
        if cols.dtype != np.int16:
            if cols.dtype.kind == "f" and not np.isfinite(cols).all():
                raise PreprocessError(f"nonfinite columns for second {ts} rejected")
            raise PreprocessError(f"columns for second {ts} must be int16 (got {cols.dtype})")
        if prev_ts is not None:
            if ts == prev_ts:
                raise PreprocessError(f"conflicting duplicate second {ts}")
            if ts < prev_ts:
                raise PreprocessError(f"clock reset / non-monotonic second {ts} after {prev_ts}")
            if ts > prev_ts + 1 and cur_start is not None:
                runs.append((cur_start, np.stack(cur_cols, axis=0)))
                cur_start, cur_cols = None, []
        if cur_start is None:
            cur_start, cur_cols = ts, [cols]
        else:
            cur_cols.append(cols)
        prev_ts = ts
    if cur_start is not None:
        runs.append((cur_start, np.stack(cur_cols, axis=0)))
    return runs


def _columns_stack_to_samples(cols: np.ndarray) -> np.ndarray:
    """(T, 600) int16 -> (T*100, 6) float64 in canonical units."""
    acc = cols[:, 0:300].reshape(-1, 3, WHOOP_SAMPLE_COUNT) * WHOOP_ACCEL_SCALE
    gyr = cols[:, 300:600].reshape(-1, 3, WHOOP_SAMPLE_COUNT) * WHOOP_GYRO_SCALE
    n = cols.shape[0] * WHOOP_SAMPLE_COUNT
    out = np.empty((n, N_CHANNELS), dtype=np.float64)
    out[:, 0:3] = acc.transpose(0, 2, 1).reshape(n, 3)
    out[:, 3:6] = gyr.transpose(0, 2, 1).reshape(n, 3)
    return out


def decode_seconds(seconds: Sequence[Tuple[int, np.ndarray]]) -> List[Run]:
    """Validate + convert (ts, columns) seconds into contiguous Runs.

    Rejects nonfinite samples (they can never become a window, spec s6),
    wrong-length columns, duplicate timestamps, clock resets and gaps >
    1 s split the data into separate runs (never concatenated, never filled).
    """
    runs: List[Run] = []
    for start_ts, cols in _asof_split(seconds):
        samples = _columns_stack_to_samples(cols)   # (T*100, 6) float
        if not np.isfinite(samples).all():
            raise PreprocessError(f"nonfinite IMU samples in run starting {start_ts}")
        runs.append(Run(start_ts=start_ts, samples=samples,
                        end_ts=start_ts + samples.shape[0] // WHOOP_SAMPLE_COUNT))
    return runs


# ---------------------------------------------------------------------------
# Windowing (4 s @ 30 Hz, 2 s hop, transient crop, request-bounded)
# ---------------------------------------------------------------------------

@dataclass
class Window:
    """One 4 s classification window, fully inside the requested interval."""
    s: float                      # nominal start (unix seconds)
    e: float                      # nominal end (unix seconds)
    data: np.ndarray              # (120, 6) float64 in g / deg/s @ 30 Hz

    def start_second(self) -> float:
        return self.s

    def end_second(self) -> float:
        return self.e


def windows_from_run(run: Run, start_ts: int, end_ts: int,
                     window_samples: int = WINDOW_SAMPLES,
                     hop_samples: int = HOP_SAMPLES,
                     margin_seconds: float = TRANSIENT_MARGIN_SECONDS,
                     ) -> List[Window]:
    """Window one contiguous run; emit only windows fully inside
    [start_ts, end_ts] and outside the FIR transient region of the run.

    Output sample k of the resampled run maps to run-relative time k/30 s
    (nominal; the polyphase filter adds a fixed ~17 ms group delay). Window
    starts land on the 30 Hz grid at run-relative seconds 0, 2, 4, ...
    """
    if run.end_ts <= start_ts or run.start_ts >= end_ts:
        return []
    res = run.resampled()                       # (30*T, 6)
    n_out = res.shape[0]
    n_per_s = TARGET_HZ
    margin_samples = int(round(margin_seconds * n_per_s))
    windows: List[Window] = []
    # Anchor the window grid to the REQUEST start_ts (not the run start), so
    # windows land on the request's integer-second grid regardless of how much
    # head overlap the worker supplied: k0 = (start_ts - run.start_ts) * 30.
    k0 = (start_ts - run.start_ts) * n_per_s
    k = k0
    while (k + window_samples) <= n_out:
        rel_start = k / n_per_s
        w_s = run.start_ts + rel_start
        w_e = w_s + window_samples / n_per_s
        inside_request = w_s >= start_ts - 1e-9 and w_e <= end_ts + 1e-9
        inside_run_margin = (k >= margin_samples) and (n_out - (k + window_samples) >= margin_samples)
        if inside_request and inside_run_margin:
            windows.append(Window(s=w_s, e=w_e, data=np.ascontiguousarray(res[k:k + window_samples])))
        k += hop_samples
        if run.start_ts + (k / n_per_s) > end_ts - 1e-9:
            break
    return windows


def windows_from_seconds(seconds: Sequence[Tuple[int, np.ndarray]],
                         start_ts: int, end_ts: int) -> List[Window]:
    """Full path: validate (ts, columns) seconds, split on gaps, resample each
    run, and window. Used by infer/serve; gaps never produce windows."""
    out: List[Window] = []
    for run in decode_seconds(seconds):
        out.extend(windows_from_run(run, start_ts, end_ts))
    out.sort(key=lambda w: w.s)
    return out


def window_energy(w: Window) -> float:
    """RMS accel-magnitude AC (g) over a window — movement-energy feature."""
    amag = np.linalg.norm(w.data[:, 0:3], axis=1)
    return float(np.sqrt(np.mean((amag - amag.mean()) ** 2)))


def validate_request_units(units: dict) -> None:
    """Canonical WHOOP units only (g, deg/s); reject unknown scaling (spec s6)."""
    if not isinstance(units, dict):
        raise PreprocessError("run.units must be an object")
    for k, expected in _CANONICAL_UNITS.items():
        got = units.get(k)
        if got != expected:
            raise PreprocessError(
                f"unsupported unit for {k}: {got!r} (canonical is {expected!r}; "
                f"conversion must be recorded in the model manifest, never here)")
