"""transition-feat-1 — engineered per-window features for the learned transition expert.

The transition modes of the ActivityContext HSMM are currently driven by one hand-designed
scalar, ``shiftStrength`` (a movement burst times a net orientation change times gait absence).
That scalar is direction-agnostic, ignores the gyroscope entirely, and only fires once the wrist
has already settled into its new orientation — seconds after the body moved. This module gives a
learned transition expert the raw material the heuristic lacks: how hard the wrist rotated, how
bursty the movement was, whether the wrist ENDED UP somewhere new (vs went-and-returned like a
gesture or reach), and the cadence that distinguishes locomotion from a posture change.

All features are computed at the NATIVE sampling rate of the source stream (20-100 Hz) with
rate-aware formulas, so a 100 Hz WHOOP stream and a 50 Hz research dataset produce comparable
values. Windows are 4 s. Every feature is a finite float or None (unresolvable, e.g. gravity too
weak) — never imputed silently; None features are skipped by the model loader.

Feature schema version: ``transition-feat-1`` (bump when a feature's meaning changes; stored
transition artifacts pin it).
"""

from __future__ import annotations

from typing import Dict, List, Optional, Tuple

import numpy as np

FEATURE_SCHEMA = "transition-feat-1"

# Canonical order — persisted in artifacts, loaded by name; NEVER reorder/rename.
FEATURE_NAMES: Tuple[str, ...] = (
    "accel_rms_g",          # RMS of gravity-removed accel magnitude (g)       [reused imu-feat-1 semantics]
    "gyro_rms_dps",         # RMS gyro magnitude (deg/s)                       [reused; RMS, matching python features.py]
    "jerk_rms",             # RMS first difference of accel magnitude (g)
    "cadence_strength",     # normalized 1.2-3.5 Hz rhythm strength (0..1)     [reused]
    "gyro_peak_dps",        # peak gyro magnitude (deg/s)
    "gyro_p95_dps",         # 95th percentile gyro magnitude (deg/s)
    "gyro_integrated_deg",  # integrated angular velocity (deg) — how far the wrist rotated in total
    "jerk_peak_g_per_s",    # peak |d(accel mag)/dt| (g/s)
    "burst_g",              # max rolling-0.5 s RMS of gravity-removed accel (g) — burstiness
    "burst_baseline_ratio", # burst_g / accel_rms_g — bursty vs continuous motion
    "net_orientation_deg",  # angle between mean gravity at window EDGES (first/last 0.5 s means)
    "orientation_path_deg", # cumulative small-angle gravity displacement over 0.1 s steps (deg)
    "path_net_ratio",       # orientation_path / (net + 5) — ~1: reached a new posture; large: went-and-returned
    "pre_gyro_mean_dps",    # mean gyro magnitude over the first 0.5 s
    "post_gyro_mean_dps",   # mean gyro magnitude over the last 0.5 s
    "cadence_hz",           # dominant rhythm frequency (Hz), 0 when none
    "gyro_mean_dps",        # mean gyro magnitude over the window
    "accel_peak_g",         # peak gravity-removed accel magnitude (g)
)

# Number of samples for edge means / rolling stats are expressed in SECONDS so native-rate
# windows of different datasets are comparable.
_EDGE_SECONDS = 0.5
_BURST_SECONDS = 0.5
_PATH_STEP_SECONDS = 0.1
_MIN_GRAVITY_NORM_G = 0.5     # below this the mean accel vector is not a usable gravity direction
_CADENCE_BAND_HZ = (1.2, 3.5)
_CADENCE_MIN_STRENGTH = 0.20


def _gravity_directions(data: np.ndarray, hz: float) -> Optional[np.ndarray]:
    """Mean accel direction per step of _PATH_STEP_SECONDS; None when gravity is unresolvable."""
    n = data.shape[0]
    if n < 2:
        return None
    step = max(1, int(round(_PATH_STEP_SECONDS * hz)))
    dirs = []
    for i in range(0, n, step):
        seg = data[i:i + step, 0:3]
        m = seg.mean(axis=0)
        if float(np.linalg.norm(m)) >= _MIN_GRAVITY_NORM_G:
            dirs.append(m)
    if len(dirs) < 2:
        return None
    return np.asarray(dirs)


def _angle_between(a: np.ndarray, b: np.ndarray) -> Optional[float]:
    na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
    if na < _MIN_GRAVITY_NORM_G or nb < _MIN_GRAVITY_NORM_G:
        return None
    cos = float(np.dot(a, b)) / (na * nb)
    return float(np.degrees(np.arccos(min(1.0, max(-1.0, cos)))))


def _cadence(accel_mag_ac: np.ndarray, hz: float) -> Tuple[float, float]:
    """Dominant 1.2-3.5 Hz autocorrelation-peak rhythm of the gravity-removed accel magnitude.

    Returns (hz, strength 0..1); (0.0, 0.0) when no peak clears the strength bar. Mirrors the
    imu-feat-1 cadence semantics (band, minimum strength) so the two schemas stay comparable.
    """
    n = accel_mag_ac.shape[0]
    if n < 8:
        return 0.0, 0.0
    x = accel_mag_ac - accel_mag_ac.mean()
    var = float(np.dot(x, x))
    if var <= 1e-12:
        return 0.0, 0.0
    # Lag range covering the 1.2-3.5 Hz band: lag = hz / freq (in samples).
    lo = max(1, int(np.floor(hz / _CADENCE_BAND_HZ[1])))
    hi = min(n - 1, int(np.ceil(hz / _CADENCE_BAND_HZ[0])))
    if hi <= lo:
        return 0.0, 0.0
    best_lag, best_r = 0, 0.0
    for lag in range(lo, hi + 1):
        a, b = x[:-lag], x[lag:]
        r = float(np.dot(a, b)) / var
        if r > best_r:
            best_r, best_lag = r, lag
    if best_r < _CADENCE_MIN_STRENGTH or best_lag <= 0:
        return 0.0, 0.0
    return round(hz / best_lag, 4), round(float(best_r), 4)


def window_transition_features(data: np.ndarray, hz: float) -> Dict[str, Optional[float]]:
    """transition-feat-1 features of one 4 s native-rate window (n, 6) — ax,ay,az[g], gx,gy,gz[deg/s].

    Deterministic, pure numpy, O(n). ``None`` marks an unresolvable feature (gravity too weak);
    the model loader skips None features rather than imputing them.
    """
    if data.ndim != 2 or data.shape[1] != 6 or data.shape[0] < 4:
        raise ValueError(f"window must be (n>=4, 6), got {data.shape}")
    if not hz or hz <= 0:
        raise ValueError(f"hz must be positive, got {hz!r}")

    acc = data[:, 0:3]
    gyr = data[:, 3:6]
    n = data.shape[0]

    # Gravity-removed accel magnitude (a 0.3 s mean is the gravity estimate, mirroring the
    # Butterworth 0.3 Hz separation HAPT applies; fast enough at any native rate).
    k = max(1, int(round(0.3 * hz)))
    pad = k // 2
    if pad and n > 2 * pad:
        padded = np.vstack([np.repeat(acc[:1], pad, axis=0), acc,
                            np.repeat(acc[-1:], pad, axis=0)])
        kernel = np.ones(2 * pad + 1) / (2 * pad + 1)
        grav = np.vstack([np.convolve(padded[:, c], kernel, mode="valid")
                          for c in range(3)]).T
    else:
        grav = np.tile(acc.mean(axis=0), (n, 1))
    ac = acc - grav
    ac_mag = np.linalg.norm(ac, axis=1)
    gyro_mag = np.linalg.norm(gyr, axis=1)

    # Rolling-0.5 s burst RMS of the gravity-removed accel.
    bk = max(1, int(round(_BURST_SECONDS * hz)))
    if n >= bk:
        csum = np.concatenate([[0.0], np.cumsum(np.square(ac_mag))])
        squares = csum[bk:] - csum[:-bk]
        burst = float(np.sqrt(squares.mean() / bk)) if squares.size else 0.0
        burst_max = float(np.sqrt(squares.max() / bk)) if squares.size else 0.0
    else:
        burst = float(np.sqrt(np.square(ac_mag).mean()))
        burst_max = burst

    # Jerk (per second, rate-aware — differences per sample scaled to seconds).
    dt = 1.0 / hz
    amag = np.linalg.norm(acc, axis=1)
    jerk = np.abs(np.diff(amag)) / dt
    jerk_rms = float(np.sqrt(np.square(jerk).mean())) if jerk.size else 0.0
    jerk_peak = float(jerk.max()) if jerk.size else 0.0

    # Orientation: edge means (0.5 s) for the NET change, cumulative path over 0.1 s steps.
    ek = max(1, int(round(_EDGE_SECONDS * hz)))
    first, last = acc[:ek].mean(axis=0), acc[-ek:].mean(axis=0)
    net = _angle_between(first, last)
    dirs = _gravity_directions(data, hz)
    path = None
    if dirs is not None and len(dirs) >= 2:
        angles = [_angle_between(dirs[i], dirs[i + 1]) for i in range(len(dirs) - 1)]
        angles = [a for a in angles if a is not None]
        if angles:
            path = float(sum(angles))
    cad_hz, cad_strength = _cadence(ac_mag, hz)

    feat: Dict[str, Optional[float]] = {
        "accel_rms_g": round(float(np.sqrt(np.square(ac_mag).mean())), 5),
        "gyro_rms_dps": round(float(np.sqrt(np.square(gyro_mag).mean())), 3),
        "jerk_rms": round(jerk_rms, 5),
        "cadence_strength": round(cad_strength, 4),
        "gyro_peak_dps": round(float(gyro_mag.max()), 3),
        "gyro_p95_dps": round(float(np.percentile(gyro_mag, 95)), 3),
        "gyro_integrated_deg": round(float(gyro_mag.sum() * dt), 3),
        "jerk_peak_g_per_s": round(jerk_peak, 4),
        "burst_g": round(burst_max, 5),
        "burst_baseline_ratio": round(burst_max / (burst + 1e-9), 4),
        "net_orientation_deg": None if net is None else round(net, 2),
        "orientation_path_deg": None if path is None else round(path, 2),
        "path_net_ratio": None if (path is None or net is None) else round(path / (net + 5.0), 4),
        "pre_gyro_mean_dps": round(float(gyro_mag[:ek].mean()), 3),
        "post_gyro_mean_dps": round(float(gyro_mag[-ek:].mean()), 3),
        "cadence_hz": round(float(cad_hz), 4),
        "gyro_mean_dps": round(float(gyro_mag.mean()), 3),
        "accel_peak_g": round(float(ac_mag.max()), 5),
    }
    return feat


def feature_matrix(rows: List[Dict[str, Optional[float]]]) -> Tuple[np.ndarray, List[str]]:
    """Stack feature dicts into a float64 matrix; unresolvable (None) entries become NaN.

    Column order is FEATURE_NAMES (the canonical persisted order). NaN cells are skipped by
    the model loader (row dropped from that tree question via default_left), never imputed.
    """
    if not rows:
        return np.zeros((0, len(FEATURE_NAMES))), list(FEATURE_NAMES)
    mat = np.full((len(rows), len(FEATURE_NAMES)), np.nan)
    for i, row in enumerate(rows):
        for j, name in enumerate(FEATURE_NAMES):
            v = row.get(name)
            if v is not None:
                mat[i, j] = float(v)
    return mat, list(FEATURE_NAMES)
