"""imu-feat-2 — compact per-window motion features published beside the encoder output.

The ActivityContext decoder (Swift, ``ActivityContextDecoder``) reasons over a window's *meaning* (the
encoder's class probabilities) and over a few encoder-independent facts about the raw motion. This module
computes those facts where the raw samples live. They are deliberately few, cheap, and not tied to HART:
swapping the encoder for another (Inertia-1, say) must not change them.

Keys mirror ``ImuWindowFeatures`` in Packages/StrandAnalytics (``ActivityContextEvidence.swift``):

  accel_rms_g              RMS of the accel-magnitude AC (gravity-removed proxy), g
  gyro_rms_dps             RMS gyro magnitude, deg/s
  jerk_rms_gps             RMS of the accel-magnitude first difference x sample rate, g/s
  cadence_hz               dominant 0.8-3.5 Hz rhythm, or None when no peak clears the strength bar
  cadence_strength         normalized strength of that rhythm, 0..1
  orientation_change_deg   angle between the mean accel (gravity) direction of the window's first and
                           second halves, or None when gravity cannot be resolved in either half

imu-feat-2 (2026) is the one cross-runtime contract both Python (30 Hz) and Swift (100 Hz) satisfy:

  * jerk_rms_gps is per-second (g/s), so it is rate-invariant up to the documented bandwidth residual
    (<=5% clean, <=10% with sensor noise; the 30 Hz anti-alias removes >15 Hz content that the 100 Hz
    differentiator still sees — WS-04-F02). The imu-feat-1 per-sample value (3.1x smaller at 100 Hz)
    is obsolete and stored output under that schema is invalidated by the bump.
  * cadence band is 0.8-3.5 Hz (widened from 1.2-3.5; slow gait). Band widening only makes the
    FEATURE honest: HART's 4-s window input contract is unchanged and slow-gait RECOGNITION needs
    ~8 s windows (WS-04-F03). The band is quantised to rate/lag: effective 0.789-3.333 Hz @30 Hz.
  * orientation_change_deg has a ~2-s horizon (half-window centers are 2 s apart in a 4 s window);
    the decoder substitutes it for the 5-s net5 only when the gravity stream is absent — 0.4x scale
    documented, decoder semantics unchanged (WS-04-F04).

Pure numpy; changing a feature's meaning requires bumping FEATURE_SCHEMA (and the Swift
``ActivityContextVersions.featureSchema``), because stored decoder output depends on it.
"""

from __future__ import annotations

from typing import Dict, Optional

import numpy as np

from .baseline import ImuFeatures, extract_features
from .preprocess import Window

FEATURE_SCHEMA = "imu-feat-2"

# Below this the mean accelerometer vector is not a usable gravity direction (free fall, dropout).
_MIN_GRAVITY_NORM_G = 0.5


def orientation_change_deg(data: np.ndarray) -> Optional[float]:
    """Angle (degrees) between the mean accel direction of the first and second half of a window.

    The half-window centers are 2 s apart in a 4 s window, so this is a ~2-s-horizon direction
    change (constant rotation w deg/s reads 2w degrees). The Swift decoder substitutes it for the
    5-s net5 when the gravity stream is absent: that is a documented 0.4x scale, unchanged here
    (WS-04-F04)."""
    n = data.shape[0]
    if n < 4:
        return None
    half = n // 2
    a = data[:half, 0:3].mean(axis=0)
    b = data[half:, 0:3].mean(axis=0)
    na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
    if na < _MIN_GRAVITY_NORM_G or nb < _MIN_GRAVITY_NORM_G:
        return None
    cos = float(np.dot(a, b)) / (na * nb)
    return float(np.degrees(np.arccos(min(1.0, max(-1.0, cos)))))


def window_features(window: Window, base: Optional[ImuFeatures] = None) -> Dict[str, Optional[float]]:
    """imu-feat-2 features of one 4 s / 120-sample window (all finite or None).

    ``base`` lets the baseline path hand over the features it already computed for its own rules."""
    data = window.data
    base = base if base is not None else extract_features(window)
    gmag2 = np.einsum("ij,ij->i", data[:, 3:6], data[:, 3:6]) if data.shape[0] else np.zeros(0)
    gyro_rms = float(np.sqrt(gmag2.mean())) if gmag2.size else 0.0
    orient = orientation_change_deg(data)
    return {
        "accel_rms_g": round(float(base.accel_energy_g), 5),
        "gyro_rms_dps": round(gyro_rms, 3),
        "jerk_rms_gps": round(float(base.jerk_rms_gps), 5),
        "cadence_hz": None if base.cadence_hz is None else round(float(base.cadence_hz), 3),
        "cadence_strength": round(float(base.cadence_strength), 4),
        "orientation_change_deg": None if orient is None else round(orient, 2),
    }
