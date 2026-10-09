"""``recgym-prep-1``: WHOOP raw IMU -> RecGym-unit windows (RECGYM.md §2).

RecGym's released IMU columns are not raw sensor readings. Measured from the dataset (RECGYM.md §2.1):

* accelerometer = gravity-free linear acceleration (a still wrist reads |a| ~ 0.14 m/s^2 in every orientation, the
  output of a fusion IMU), normalised ``clip(0.5 + a / 80, 0, 1)`` with ``a`` in m/s^2 (the unclipped values span
  exactly ±39.99 m/s^2 on a 0.01 m/s^2 grid);
* gyroscope = angular rate normalised ``clip(0.5 + w / 1600, 0, 1)`` with ``w`` in deg/s (unclipped values span
  ±799.9 deg/s; 1/16 deg/s steps rounded to 0.01);
* sampled at 20 Hz.

The WHOOP strap gives 100 Hz accelerometer in g WITH gravity and gyroscope in deg/s (``activity_context.preprocess``:
1/4096 g and 2000/32768 deg/s per LSB). Per contiguous run this module:

1. removes gravity with a Madgwick IMU (6-axis) orientation filter at 100 Hz (gain ``MADGWICK_BETA``, initialised
   from the first half second's mean acceleration), the published equivalent of the fusion output RecGym recorded:
   linear acceleration = (a - g_sensor) * 9.80665 m/s^2;
2. resamples linear acceleration and angular rate 100 -> 20 Hz with the package's anti-alias polyphase FIR
   (``resample_poly_nd(x, 1, 5)``, identical to ``scipy.signal.resample_poly``);
3. maps to RecGym units with the clipping above;
4. cuts 4 s windows (80 samples) on the absolute 2 s grid (window starts are even unix seconds, so a window's key never
   depends on how the worker chunked the day), fully inside the request and at least ``HEAD_MARGIN_S`` after the run
   start (filter settling) and ``TAIL_MARGIN_S`` before its end (FIR support).

Axes are passed through unchanged (strap x, y, z -> A_x, A_y, A_z and G_x, G_y, G_z). RecGym's sensor axes relative
to the wrist are undocumented and the WHOOP axis convention is itself unverified (docs/model-integration/
sensor-families.md), so the mapping is ``identity_unverified``; on top of that the model was trained on the wrist
and the owner wears the strap on the upper arm. Both are recorded with every output.

Gaps and clock resets split runs (``activity_context.preprocess.decode_seconds``); missing seconds are never filled.
All functions are deterministic and pure.
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from typing import Dict, List, Sequence, Tuple

import numpy as np

from ..preprocess import Run, decode_seconds, resample_poly_nd
from . import (ACCEL_FULL_SCALE_MS2, GYRO_FULL_SCALE_DPS, HOP_S, PREPROCESSING_VERSION, RATE_HZ, STANDARD_GRAVITY,
               WINDOW_S, WINDOW_SAMPLES)

SOURCE_HZ = 100
DOWN = SOURCE_HZ // RATE_HZ                    # 5
MADGWICK_BETA = 0.1                             # the reference implementation's default gain
INIT_SECONDS = 0.5                              # orientation initialised from this span's mean acceleration
HEAD_MARGIN_S = 2                               # filter settling after a run start (inside the lane's 3 s head)
TAIL_MARGIN_S = 1                               # FIR support before a run end (half-length 0.5 s)
AXIS_MAPPING = "identity_unverified"

PREPROCESSING: Dict[str, object] = {
    "version": PREPROCESSING_VERSION,
    "gravity": f"madgwick_imu beta={MADGWICK_BETA} at {SOURCE_HZ} Hz, init from first {INIT_SECONDS} s mean accel",
    "resampler": f"anti-alias polyphase FIR 1/{DOWN} (= scipy.signal.resample_poly)",
    "units": {"accel": f"clip(0.5 + a_lin_ms2 / {2 * ACCEL_FULL_SCALE_MS2:g}, 0, 1)",
              "gyro": f"clip(0.5 + w_dps / {2 * GYRO_FULL_SCALE_DPS:g}, 0, 1)"},
    "rate_hz": RATE_HZ, "window_s": WINDOW_S, "hop_s": HOP_S, "grid": "absolute even unix seconds",
    "head_margin_s": HEAD_MARGIN_S, "tail_margin_s": TAIL_MARGIN_S, "axis_mapping": AXIS_MAPPING,
}


@dataclass
class ExerciseWindow:
    """One 4 s window in RecGym units, with the digest of the raw seconds it covers."""
    s: int                      # unix start (even)
    e: int                      # s + 4
    data: np.ndarray            # (80, 6) float64 in RecGym units
    input_sha256: str           # sha256 of the four seconds' raw int16 columns (600 i16 LE each, in time order)


def initial_quaternion(accel_g: np.ndarray) -> Tuple[float, float, float, float]:
    """Earth-to-sensor quaternion whose gravity direction is the mean of ``accel_g`` (yaw 0)."""
    a = np.asarray(accel_g, dtype=np.float64).reshape(-1, 3).mean(axis=0)
    n = float(np.linalg.norm(a))
    if not math.isfinite(n) or n == 0.0:
        return 1.0, 0.0, 0.0, 0.0
    ax, ay, az = (a / n).tolist()
    roll = math.atan2(ay, az)
    pitch = math.atan2(-ax, math.sqrt(ay * ay + az * az))
    cr, sr, cp, sp = math.cos(roll / 2), math.sin(roll / 2), math.cos(pitch / 2), math.sin(pitch / 2)
    return cr * cp, sr * cp, cr * sp, -sr * sp


def gravity_direction(samples: np.ndarray, beta: float = MADGWICK_BETA, fs: float = SOURCE_HZ) -> np.ndarray:
    """(T, 6) [g, deg/s] -> (T, 3) unit gravity direction in the sensor frame after each sample's Madgwick IMU update
    (S. Madgwick 2010, MadgwickAHRSupdateIMU; the gradient step is skipped for a zero accelerometer sample)."""
    x = np.asarray(samples, dtype=np.float64)
    n = x.shape[0]
    out = np.empty((n, 3), dtype=np.float64)
    if n == 0:
        return out
    q0, q1, q2, q3 = initial_quaternion(x[: max(1, int(INIT_SECONDS * fs)), 0:3])
    dt = 1.0 / fs
    d2r = math.pi / 180.0
    rows = x.tolist()
    for i in range(n):
        ax, ay, az, gx, gy, gz = rows[i]
        gx *= d2r
        gy *= d2r
        gz *= d2r
        qd0 = 0.5 * (-q1 * gx - q2 * gy - q3 * gz)
        qd1 = 0.5 * (q0 * gx + q2 * gz - q3 * gy)
        qd2 = 0.5 * (q0 * gy - q1 * gz + q3 * gx)
        qd3 = 0.5 * (q0 * gz + q1 * gy - q2 * gx)
        an = ax * ax + ay * ay + az * az
        if an > 0.0:
            r = 1.0 / math.sqrt(an)
            ax *= r
            ay *= r
            az *= r
            _2q0, _2q1, _2q2, _2q3 = 2.0 * q0, 2.0 * q1, 2.0 * q2, 2.0 * q3
            _4q0, _4q1, _4q2 = 4.0 * q0, 4.0 * q1, 4.0 * q2
            _8q1, _8q2 = 8.0 * q1, 8.0 * q2
            q0q0, q1q1, q2q2, q3q3 = q0 * q0, q1 * q1, q2 * q2, q3 * q3
            s0 = _4q0 * q2q2 + _2q2 * ax + _4q0 * q1q1 - _2q1 * ay
            s1 = _4q1 * q3q3 - _2q3 * ax + 4.0 * q0q0 * q1 - _2q0 * ay - _4q1 + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * az
            s2 = 4.0 * q0q0 * q2 + _2q0 * ax + _4q2 * q3q3 - _2q3 * ay - _4q2 + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * az
            s3 = 4.0 * q1q1 * q3 - _2q1 * ax + 4.0 * q2q2 * q3 - _2q2 * ay
            sn = s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3
            if sn > 0.0:
                r = beta / math.sqrt(sn)
                qd0 -= r * s0
                qd1 -= r * s1
                qd2 -= r * s2
                qd3 -= r * s3
        q0 += qd0 * dt
        q1 += qd1 * dt
        q2 += qd2 * dt
        q3 += qd3 * dt
        r = 1.0 / math.sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3)
        q0 *= r
        q1 *= r
        q2 *= r
        q3 *= r
        out[i, 0] = 2.0 * (q1 * q3 - q0 * q2)
        out[i, 1] = 2.0 * (q0 * q1 + q2 * q3)
        out[i, 2] = q0 * q0 - q1 * q1 - q2 * q2 + q3 * q3
    return out


def linear_acceleration_ms2(samples: np.ndarray) -> np.ndarray:
    """(T, 6) [g, deg/s] -> (T, 3) gravity-free acceleration in m/s^2."""
    x = np.asarray(samples, dtype=np.float64)
    return (x[:, 0:3] - gravity_direction(x)) * STANDARD_GRAVITY


def to_recgym_units(accel_ms2: np.ndarray, gyro_dps: np.ndarray) -> np.ndarray:
    """Linear acceleration (m/s^2) and angular rate (deg/s) -> RecGym's released, clipped [0, 1] units, (T, 6)."""
    a = 0.5 + np.asarray(accel_ms2, dtype=np.float64) / (2.0 * ACCEL_FULL_SCALE_MS2)
    g = 0.5 + np.asarray(gyro_dps, dtype=np.float64) / (2.0 * GYRO_FULL_SCALE_DPS)
    return np.clip(np.concatenate([a, g], axis=1), 0.0, 1.0)


def run_recgym_units(run: Run) -> np.ndarray:
    """One contiguous run (100 Hz, g / deg/s) -> (20 * seconds, 6) RecGym units at 20 Hz, sample k at
    ``run.start_ts + k / 20`` s."""
    lin = linear_acceleration_ms2(run.samples)
    physical = np.concatenate([lin, run.samples[:, 3:6]], axis=1)
    res = resample_poly_nd(physical, 1, DOWN, axis=0)
    return to_recgym_units(res[:, 0:3], res[:, 3:6])


def _input_sha256(raw: Dict[int, np.ndarray], s: int) -> str:
    h = hashlib.sha256()
    for t in range(s, s + WINDOW_S):
        h.update(np.ascontiguousarray(raw[t], dtype="<i2").tobytes())
    return h.hexdigest()


def windows_from_run(run: Run, start_ts: int, end_ts: int, raw: Dict[int, np.ndarray]) -> List[ExerciseWindow]:
    """Windows of one run on the absolute even-second grid, inside [start_ts, end_ts) and the run's margins."""
    lo = max(start_ts, run.start_ts + HEAD_MARGIN_S)
    hi = min(end_ts, run.end_ts - TAIL_MARGIN_S)
    first = lo + (lo % HOP_S)
    if first + WINDOW_S > hi:
        return []
    res = run_recgym_units(run)
    out: List[ExerciseWindow] = []
    s = first
    while s + WINDOW_S <= hi:
        k0 = (s - run.start_ts) * RATE_HZ
        data = res[k0:k0 + WINDOW_SAMPLES]
        if data.shape[0] == WINDOW_SAMPLES:
            out.append(ExerciseWindow(s=s, e=s + WINDOW_S, data=np.ascontiguousarray(data),
                                      input_sha256=_input_sha256(raw, s)))
        s += HOP_S
    return out


def windows_from_seconds(seconds: Sequence[Tuple[int, np.ndarray]], start_ts: int,
                         end_ts: int) -> List[ExerciseWindow]:
    """(ts, 600 int16 columns) seconds (head + body + tail) -> windows inside [start_ts, end_ts), in time order.
    Raises ``PreprocessError`` on malformed, duplicate or non-monotonic seconds (the shared decoder's rules)."""
    raw = {int(ts): cols for ts, cols in seconds}
    out: List[ExerciseWindow] = []
    for run in decode_seconds(seconds):
        out.extend(windows_from_run(run, start_ts, end_ts, raw))
    out.sort(key=lambda w: w.s)
    return out


def stack_windows(windows: Sequence[ExerciseWindow]) -> np.ndarray:
    if not windows:
        return np.zeros((0, WINDOW_SAMPLES, 6), np.float64)
    return np.stack([w.data for w in windows], axis=0)


__all__ = ["SOURCE_HZ", "MADGWICK_BETA", "HEAD_MARGIN_S", "TAIL_MARGIN_S", "AXIS_MAPPING", "PREPROCESSING",
           "ExerciseWindow", "initial_quaternion", "gravity_direction", "linear_acceleration_ms2", "to_recgym_units",
           "run_recgym_units", "windows_from_run", "windows_from_seconds", "stack_windows"]
